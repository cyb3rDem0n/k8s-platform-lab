package lab.hello;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;

/**
 * Client minimale per l'API REST di Ollama (POST /api/generate, stream=false).
 * Ollama gira DENTRO il cluster (namespace "ai"): il backend lo raggiunge tramite il DNS
 * interno del Service, e la NetworkPolicy consente solo questo flusso.
 */
final class OllamaClient {
    private final HttpClient http;
    private final URI generateUri;
    private final String model;
    private final Duration timeout;

    OllamaClient(String baseUrl, String model, Duration timeout) {
        this.http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
        this.generateUri = URI.create(baseUrl.replaceAll("/+$", "") + "/api/generate");
        this.model = model;
        this.timeout = timeout;
    }

    String model() { return model; }

    String generate(String prompt) throws IOException, InterruptedException {
        String body = Json.obj(Map.of(
                "model", model,
                "prompt", prompt,
                "stream", false,
                "options", Map.of("num_predict", 256)
        ));
        HttpRequest req = HttpRequest.newBuilder(generateUri)
                .timeout(timeout)
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();
        HttpResponse<String> res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2) {
            throw new IOException("Ollama ha risposto " + res.statusCode() + ": " + res.body());
        }
        String answer = Json.extractString(res.body(), "response");
        if (answer == null) throw new IOException("Risposta Ollama senza campo 'response'");
        return answer.strip();
    }
}
