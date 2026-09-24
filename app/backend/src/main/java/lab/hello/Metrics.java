package lab.hello;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.LongAdder;

/**
 * Metriche in formato testo Prometheus (exposition format), scritte a mano.
 * Espone un contatore di richieste per path e codice HTTP e un gauge di "readiness".
 * Prometheus le raccoglie via GET /metrics (vedi capitolo osservabilità del tutorial).
 */
final class Metrics {
    private final Map<String, LongAdder> requests = new ConcurrentHashMap<>();
    private final long startedAtMillis = System.currentTimeMillis();

    void record(String path, int status) {
        requests.computeIfAbsent(path + "|" + status, k -> new LongAdder()).increment();
    }

    String render(boolean ready) {
        StringBuilder b = new StringBuilder();
        b.append("# HELP hello_http_requests_total Richieste HTTP servite, per path e status.\n");
        b.append("# TYPE hello_http_requests_total counter\n");
        requests.forEach((k, v) -> {
            String[] p = k.split("\\|", 2);
            b.append("hello_http_requests_total{path=\"").append(p[0])
             .append("\",status=\"").append(p[1]).append("\"} ").append(v.sum()).append('\n');
        });
        b.append("# HELP hello_ready 1 se il processo accetta traffico, 0 durante lo shutdown.\n");
        b.append("# TYPE hello_ready gauge\n");
        b.append("hello_ready ").append(ready ? 1 : 0).append('\n');
        b.append("# HELP hello_uptime_seconds Secondi dall'avvio del processo.\n");
        b.append("# TYPE hello_uptime_seconds gauge\n");
        b.append("hello_uptime_seconds ").append((System.currentTimeMillis() - startedAtMillis) / 1000).append('\n');
        return b.toString();
    }
}
