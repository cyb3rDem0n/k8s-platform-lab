package lab.hello;

import java.util.Map;
import java.util.StringJoiner;

/**
 * Serializzazione JSON minimale, senza dipendenze esterne.
 * Scelta didattica: l'immagine resta piccola e non c'è supply chain da gestire.
 * In un servizio reale useresti Jackson o simili.
 */
final class Json {
    private Json() {}

    static String obj(Map<String, ?> fields) {
        StringJoiner sj = new StringJoiner(",", "{", "}");
        fields.forEach((k, v) -> sj.add(str(k) + ":" + value(v)));
        return sj.toString();
    }

    private static String value(Object v) {
        if (v == null) return "null";
        if (v instanceof Number || v instanceof Boolean) return v.toString();
        if (v instanceof Map<?, ?> m) {
            @SuppressWarnings("unchecked") Map<String, ?> mm = (Map<String, ?>) m;
            return obj(mm);
        }
        return str(v.toString());
    }

    static String str(String s) {
        StringBuilder b = new StringBuilder(s.length() + 2).append('"');
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"' -> b.append("\\\"");
                case '\\' -> b.append("\\\\");
                case '\n' -> b.append("\\n");
                case '\r' -> b.append("\\r");
                case '\t' -> b.append("\\t");
                default -> {
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
                }
            }
        }
        return b.append('"').toString();
    }

    /** Estrae un campo stringa di primo livello da un JSON semplice (sufficiente per la risposta di Ollama). */
    static String extractString(String json, String field) {
        String key = "\"" + field + "\"";
        int i = json.indexOf(key);
        if (i < 0) return null;
        i = json.indexOf(':', i + key.length());
        if (i < 0) return null;
        i = json.indexOf('"', i);
        if (i < 0) return null;
        StringBuilder out = new StringBuilder();
        for (int p = i + 1; p < json.length(); p++) {
            char c = json.charAt(p);
            if (c == '\\' && p + 1 < json.length()) {
                char n = json.charAt(++p);
                switch (n) {
                    case 'n' -> out.append('\n');
                    case 't' -> out.append('\t');
                    case 'r' -> out.append('\r');
                    case 'u' -> {
                        out.append((char) Integer.parseInt(json.substring(p + 1, p + 5), 16));
                        p += 4;
                    }
                    default -> out.append(n);
                }
            } else if (c == '"') {
                return out.toString();
            } else {
                out.append(c);
            }
        }
        return null;
    }
}
