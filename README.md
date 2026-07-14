# Trabalho Pratico - Sistemas Distribuidos 2026/1

## Arquitetura

Aplicacao distribuidas com 3 componentes:

1. **Gateway** (Flask) - Circuit Breaker, Retry, Timeout
2. **Servico** (Flask) - Cache com Redis
3. **Redis** - Cache

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

# 5. Instalar Chaos Mesh (via Helm)
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --create-namespace

# 6. Aplicar experimentos de caos
kubectl apply -f chaos/

# 7. Testar
curl http://localhost:30000/api/data
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
│   ├── gateway/        # API Gateway (Flask)
│   └── servico/        # Microservico (Flask + Redis)
├── docker/             # Dockerfiles
├── k8s/                # Manifestos Kubernetes
├── chaos/              # Manifestos Chaos Mesh
├── relatorio/          # Relatorio Tecnico
└── README.md
```
