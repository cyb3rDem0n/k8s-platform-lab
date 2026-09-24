# k8s/learn — manifest "usa e getta" dei capitoli introduttivi

Questi file servono per imparare, uno strato alla volta, come si raggiunge un'applicazione
dall'esterno. NON fanno parte dello stato desiderato gestito da Argo CD: applicali a mano,
osserva, poi cancellali (`kubectl delete -f <file>`).

- `stage-05-core/`             il nucleo dell'app (capitolo 5), con i tag immagine impostati
- `01-pod-debug.yaml`         un Pod effimero con curl per test dall'interno del cluster
- `02-frontend-nodeport.yaml` espone il frontend su una porta alta di OGNI nodo (30080)
- `03-frontend-loadbalancer.yaml` chiede un IP dedicato a MetalLB (Service type LoadBalancer)
