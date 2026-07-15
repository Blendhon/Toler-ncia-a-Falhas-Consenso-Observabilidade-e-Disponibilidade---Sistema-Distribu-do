# Trabalho Pratico - Sistemas Distribuidos 2026/1

## Arquitetura

Aplicacao distribuidas com 3 componentes:

1. **Gateway** (Flask) - Circuit Breaker, Retry, Timeout
2. **Servico** (Flask) - Cache com Redis
3. **Redis** - Cache

### Observabilidade

- **Prometheus** - Coleta de metricas (port 30090)
- **Grafana** - Dashboards (port 30030, admin/admin)
- **Redis Exporter** - Metricas Redis para Prometheus

## Pre-requisitos

- Docker
- Kind (Kubernetes in Docker)
- kubectl
- Helm (para instalar Chaos Mesh)

## Como Executar

```bash
# 1. Criar cluster Kind
kind create cluster --config kind-config.yaml

# 2. Build das imagens
docker build -t gateway:latest -f docker/gateway.Dockerfile .
docker build -t servico:latest -f docker/servico.Dockerfile .

# 3. Load images no Kind
kind load docker-image gateway:latest
kind load docker-image servico:latest

# 4. Deploy da aplicacao
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/

# 5. Deploy do monitoring stack
kubectl apply -f k8s/monitoring/

# 6. Instalar Chaos Mesh (via Helm)
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --create-namespace

# 7. Aplicar experimentos de caos
kubectl apply -f chaos/

# 8. Testar
curl http://localhost:30000/api/data

# 9. Acessar Prometheus
kubectl port-forward -n trabalho-sis-dis svc/prometheus 30090:9090
# http://localhost:30090

# 10. Acessar Grafana
kubectl port-forward -n trabalho-sis-dis svc/grafana 30030:3000
# http://localhost:30030 (admin / admin)
```

## Experimentos de Caos

| Experimento | Tipo | Descricao |
|------------|------|-----------|
| NetworkChaos | Rede | Latencia 500ms + perda 30% pacotes |
| PodChaos | Instancia | Kill de pod durante reqs ativas |
| StressChaos | Recurso | Sobrecarga CPU 80% |

## Estrutura

```
.
├── app/
│   ├── gateway/        # API Gateway (Flask + metrics)
│   └── servico/        # Microservico (Flask + Redis + metrics)
├── docker/             # Dockerfiles
├── k8s/                # Manifestos Kubernetes
│   ├── monitoring/     # Prometheus, Grafana, Redis Exporter
├── chaos/              # Manifestos Chaos Mesh
├── relatorio/          # Relatorio Tecnico
└── README.md
```
