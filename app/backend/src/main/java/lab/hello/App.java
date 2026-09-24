package lab.hello;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Backend didattico: solo JDK (com.sun.net.httpserver + java.net.http), nessun framework.
 *
 * Endpoint:
 *   GET  /api/hello          saluto + hostname del Pod (utile per vedere il load balancing)
 *   GET  /api/info           metadati non sensibili (versione, ambiente, se il token è impostato)
 *   POST /api/ask            prompt -> LLM locale (Ollama), protetto da header X-Api-Token (Secret)
 *   GET  /healthz/live       liveness: il processo è vivo
 *   GET  /healthz/ready      readiness: il processo accetta traffico (false durante lo shutdown)
 *   GET  /metrics            metriche Prometheus
 */
public final class App {

    private static final String VERSION = System.getenv().getOrDefault("APP_VERSION", "dev");

    private final Config cfg;
    private final Metrics metrics = new Metrics();
    private final AtomicBoolean ready = new AtomicBoolean(false);
    private final OllamaClient ollama;
    private final String hostname;
    private HttpServer server;

    App(Config cfg) {
        this.cfg = cfg;
        this.ollama = new OllamaClient(cfg.ollamaUrl(), cfg.ollamaModel(), cfg.ollamaTimeout());
        this.hostname = resolveHostname();
    }

    public static void main(String[] args) throws IOException {
        Config cfg = Config.fromEnv();
        log("avvio " + cfg);
        App app = new App(cfg);
        app.start();
        Runtime.getRuntime().addShutdownHook(new Thread(app::shutdown, "shutdown"));
    }

    void start() throws IOException {
        server = HttpServer.create(new InetSocketAddress(cfg.port()), 0);
        // Virtual thread per richiesta: ideale per I/O bloccante (es. chiamata all'LLM).
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());

        server.createContext("/api/hello", ex -> handle(ex, "GET", () -> reply(ex, 200, Json.obj(ordered(
                "message", cfg.greeting(),
                "pod", hostname,
                "version", VERSION,
                "time", Instant.now().toString())))));

        server.createContext("/api/info", ex -> handle(ex, "GET", () -> reply(ex, 200, Json.obj(ordered(
                "app", cfg.appName(),
                "environment", cfg.environment(),
                "version", VERSION,
                "java", Runtime.version().toString(),
                "apiTokenConfigured", cfg.apiToken().isPresent(),
                "llmModel", ollama.model())))));

        server.createContext("/api/ask", ex -> handle(ex, "POST", () -> ask(ex)));

        server.createContext("/healthz/live", ex -> handle(ex, "GET",
                () -> reply(ex, 200, "{\"status\":\"UP\"}")));

        server.createContext("/healthz/ready", ex -> handle(ex, "GET", () -> {
            if (ready.get()) reply(ex, 200, "{\"status\":\"READY\"}");
            else reply(ex, 503, "{\"status\":\"NOT_READY\"}");
        }));

        server.createContext("/metrics", ex -> handle(ex, "GET", () -> {
            byte[] body = metrics.render(ready.get()).getBytes(StandardCharsets.UTF_8);
            ex.getResponseHeaders().set("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
            ex.sendResponseHeaders(200, body.length);
            try (OutputStream os = ex.getResponseBody()) { os.write(body); }
        }));

        server.createContext("/", ex -> handle(ex, null,
                () -> reply(ex, 404, "{\"error\":\"not found\"}")));

        server.start();
        ready.set(true);
        log("in ascolto su :" + cfg.port() + " (pod " + hostname + ", versione " + VERSION + ")");
    }

    /**
     * Graceful shutdown in due fasi, pensato per Kubernetes:
     * 1) readiness -> 503: l'endpoint viene tolto dagli EndpointSlice e il Gateway smette di inviarci traffico;
     * 2) attesa shutdownDelay (tempo di propagazione), poi stop con grace per le richieste in corso.
     * La somma deve stare sotto terminationGracePeriodSeconds del Pod.
     */
    void shutdown() {
        log("SIGTERM ricevuto: readiness -> false, attendo " + cfg.shutdownDelay().toSeconds() + "s");
        ready.set(false);
        sleep(cfg.shutdownDelay().toMillis());
        server.stop((int) cfg.shutdownGrace().toSeconds());
        log("server fermato, bye");
    }

    private void ask(HttpExchange ex) throws IOException {
        if (cfg.apiToken().isEmpty()) {
            reply(ex, 503, "{\"error\":\"API_TOKEN non configurato: endpoint disabilitato\"}");
            return;
        }
        String provided = ex.getRequestHeaders().getFirst("X-Api-Token");
        if (provided == null || !constantTimeEquals(provided, cfg.apiToken().get())) {
            reply(ex, 401, "{\"error\":\"token mancante o errato\"}");
            return;
        }
        String prompt = readBody(ex.getRequestBody(), 4_096).strip();
        if (prompt.isEmpty()) {
            reply(ex, 400, "{\"error\":\"body vuoto: invia il prompt come testo semplice\"}");
            return;
        }
        try {
            long t0 = System.nanoTime();
            String answer = ollama.generate(prompt);
            long ms = (System.nanoTime() - t0) / 1_000_000;
            reply(ex, 200, Json.obj(ordered("model", ollama.model(), "latencyMs", ms, "answer", answer)));
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            reply(ex, 504, "{\"error\":\"richiesta interrotta\"}");
        } catch (IOException ioe) {
            log("errore LLM: " + ioe.getMessage());
            reply(ex, 502, Json.obj(ordered("error", "LLM non raggiungibile", "detail", ioe.getMessage())));
        }
    }

    // ---- infrastruttura HTTP ---------------------------------------------------------------

    @FunctionalInterface
    private interface IoAction { void run() throws IOException; }

    private void handle(HttpExchange ex, String method, IoAction action) {
        String path = ex.getHttpContext().getPath();
        try {
            if (method != null && !method.equalsIgnoreCase(ex.getRequestMethod())) {
                reply(ex, 405, "{\"error\":\"metodo non consentito\"}");
            } else {
                action.run();
            }
        } catch (Exception e) {
            log("errore su " + path + ": " + e);
            try { reply(ex, 500, "{\"error\":\"internal\"}"); } catch (IOException ignored) { }
        } finally {
            metrics.record(path, ex.getResponseCode());
            ex.close();
        }
    }

    private static void reply(HttpExchange ex, int status, String json) throws IOException {
        byte[] body = json.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        ex.getResponseHeaders().set("Cache-Control", "no-store");
        ex.sendResponseHeaders(status, body.length);
        try (OutputStream os = ex.getResponseBody()) { os.write(body); }
    }

    private static String readBody(InputStream in, int max) throws IOException {
        byte[] data = in.readNBytes(max + 1);
        if (data.length > max) throw new IOException("body troppo grande (max " + max + " byte)");
        return new String(data, StandardCharsets.UTF_8);
    }

    /** Confronto a tempo costante: evita timing attack sul token. */
    private static boolean constantTimeEquals(String a, String b) {
        return MessageDigest.isEqual(a.getBytes(StandardCharsets.UTF_8), b.getBytes(StandardCharsets.UTF_8));
    }

    private static Map<String, Object> ordered(Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put((String) kv[i], kv[i + 1]);
        return m;
    }

    private static String resolveHostname() {
        String h = System.getenv("HOSTNAME"); // in un Pod = nome del Pod
        if (h != null && !h.isBlank()) return h;
        try { return InetAddress.getLocalHost().getHostName(); } catch (IOException e) { return "unknown"; }
    }

    private static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }

    /** Log su stdout, una riga per evento: Kubernetes raccoglie stdout/stderr (12-factor, fattore XI). */
    static void log(String msg) {
        System.out.println(Instant.now() + " [" + Thread.currentThread().getName() + "] " + msg);
    }
}
