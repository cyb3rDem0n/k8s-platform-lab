package lab.hello;

import java.time.Duration;
import java.util.Optional;

/**
 * Configurazione dell'applicazione letta ESCLUSIVAMENTE da variabili d'ambiente
 * (12-factor, fattore III). In Kubernetes arrivano da ConfigMap (valori non sensibili)
 * e da Secret (valori sensibili). Nessun file di configurazione dentro l'immagine:
 * la stessa immagine gira identica in ogni ambiente.
 */
public record Config(
        int port,
        String appName,
        String environment,
        String greeting,
        Duration shutdownDelay,
        Duration shutdownGrace,
        Optional<String> apiToken,
        String ollamaUrl,
        String ollamaModel,
        Duration ollamaTimeout
) {

    public static Config fromEnv() {
        return new Config(
                intEnv("PORT", 8080),
                env("APP_NAME", "hello-backend"),
                env("APP_ENV", "local"),
                env("GREETING", "Ciao dal backend Java su Kubernetes"),
                Duration.ofSeconds(intEnv("SHUTDOWN_DELAY_SECONDS", 5)),
                Duration.ofSeconds(intEnv("SHUTDOWN_GRACE_SECONDS", 10)),
                Optional.ofNullable(System.getenv("API_TOKEN")).filter(s -> !s.isBlank()),
                env("OLLAMA_URL", "http://ollama.ai.svc.cluster.local:11434"),
                env("OLLAMA_MODEL", "qwen2.5:1.5b"),
                Duration.ofSeconds(intEnv("OLLAMA_TIMEOUT_SECONDS", 120))
        );
    }

    private static String env(String key, String def) {
        String v = System.getenv(key);
        return (v == null || v.isBlank()) ? def : v;
    }

    private static int intEnv(String key, int def) {
        String v = System.getenv(key);
        if (v == null || v.isBlank()) return def;
        try {
            return Integer.parseInt(v.trim());
        } catch (NumberFormatException e) {
            throw new IllegalStateException("Variabile " + key + " non numerica: " + v, e);
        }
    }

    /** Rappresentazione loggabile: MAI stampare i segreti, solo se sono presenti. */
    @Override
    public String toString() {
        return "Config[port=" + port + ", appName=" + appName + ", env=" + environment
                + ", apiToken=" + (apiToken.isPresent() ? "<impostato>" : "<assente>")
                + ", ollamaUrl=" + ollamaUrl + ", ollamaModel=" + ollamaModel + "]";
    }
}
