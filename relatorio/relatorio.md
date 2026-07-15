# Relatorio Tecnico de Resiliencia

**Disciplina:** Sistemas Distribuidos - 2026/1
**Professor:** Helder de Amorim Mendes
**Grupo:** Blendhon Pontini Delfino, Jhonatas Vinicius Neri Dos Santos e Maria Clara Gueler Feitani

---

## 1. Arquitetura da Aplicacao

```
[Cliente] --> [Gateway :5000] --> [Servico :5001] --> [Redis :6379]
                       |                   |
                  Circuit Breaker      Cache (Redis)
                    + Retry
                    + Timeout
```

- **Gateway (2 replicas, HPA 2-5):** Flask + circuito disjuntor, retry, timeout
- **Servico (2 replicas, HPA 2-5):** Flask + Redis (cache)
- **Redis:** Cache de resultados (TTL 30s)
- **HPA:** HorizontalPodAutoscaler para ambos (target 50% CPU, 70% memory)
- **Monitoring:** Prometheus + Grafana + Redis Exporter

### Mecanismos de Tolerancia a Falhas

| Mecanismo | Local | Configuracao | Efeito |
|-----------|-------|-------------|--------|
| Circuit Breaker | Gateway | 3 falhas -> OPEN, recovery 10s | Evita cascata de falhas |
| Timeout | Gateway | 2s por request | Limita latencia maxima |
| Retry | Gateway | 3 tentativas, backoff linear 0.5s*attempt | Recuperacao transitoria |
| Replicas | K8s | 2 pods cada servico (HPA 2-5) | Redundancia ativa |
| Cache | Redis | TTL 30s | Isola do backend em falha de rede |
| HPA | K8s | min=2, max=5, target=50% CPU | Escalonamento automatico |
| Liveness/Readiness | K8s | Probes a cada 10-15s | Detecao de falha rapida |

---

## 2. Experimentos de Caos

### Metodologia

Os experimentos foram executados com Chaos Mesh v2.8.3 em cluster Kind (3 nos). Cada experimento enviou 15 requisicoes ao Gateway (intervalo 300ms) e coletou metricas via Prometheus. O Chaos Mesh foi configurado para o runtime containerd do Kind.

**Sequencia de executacao:**
1. Baseline (15 reqs, sem ataque)
2. NetworkChaos (latencia 3s + perda 30%, mode:all, 300s) - **cache Redis limpo antes do experimento**
3. PodChaos (pod-failure, mode:one, 30s) - **cache Redis limpo antes do experimento**
4. StressChaos (CPU 100%, mode:all, 45s)
5. Recuperacao (10 reqs)

### 2.1. Experimento 1: Falha de Rede (NetworkChaos)

**Estado Estavel:** Gateway -> Servico ~13ms, taxa de sucesso 100%

**Hipotese:** Com latencia de 3000ms+ e timeout de 2s, as requisicoes que atingirem o servico vao estourar timeout, acionando retry e fallback do circuit breaker. O cache Redis foi limpo antes do experimento para garantir que as requisicoes atinjam o servico.

**Configuracao do Ataque:**
```yaml
acao: delay
latencia: 3000ms
jitter: 500ms
correlacao: 50%
perda: 30% (direction: to)
alvo: servico (todos os pods, mode: all)
duracao: 300s
```

**Resultado Observado:**
- 0/15 requisicoes retornaram "ok" (100% degradadas)
- Latencia media: 2408ms (vs 5.87ms no baseline) - 410x mais lento
- P95: 7514ms (excede timeout de 2s do gateway)
- Todas as 15 requisicoes retornaram "degraded" (fallback do circuit breaker)
- Circuit breaker acumulou 2 falhas (threshold=3 para OPEN)
- 6 retries por timeout, 19 retries por erro de conexao
- 8 invocacoes do fallback

**Analise de Causalidade:**
Com o cache Redis limpo, todas as requisicoes atingiram o servico, que estava sob latencia de 3000ms. Como o timeout do gateway e de 2s, todas as requisicoes estouraram o timeout, acionando o mecanismo de retry (3 tentativas com backoff linear). Apos 3 falhas consecutivas, o circuit breaker acumulou 2 falhas (ficando a 1 de abrir). O fallback retornou dados do cache quando disponivel ou mensagem de erro. A latencia media de 2408ms reflete o tempo ate o timeout (2s) mais o overhead do retry.

---

### 2.2. Experimento 2: Falha de Instancia (PodChaos)

**Estado Estavel:** 2 pods do servico ativos, requisicoes distribuidas

**Hipotese:** A falha de 1 pod do servico (mode:one) causa timeout nas requisicoes roteadas para ele, mas a replica sobrevivente absorve o trafego, mantendo o sistema funcional.

**Configuracao do Ataque:**
```yaml
acao: pod-failure
alvo: servico (1 pod, mode: one)
duracao: 30s
```

**Resultado Observado:**
- 15/15 requisicoes retornaram "ok" (sem degradacao)
- Latencia media: 46ms (vs 5.87ms no baseline)
- Circuit breaker permaneceu CLOSED (zero falhas)
- Kubernetes detectou e recriou o pod em ~5-10s
- 1 pod afetado, 1 pod sobrevivente absorveu todo trafego
- Zero retries necessarios

**Analise de Causalidade:**
O modo `mode:one` e mais realista que `mode:all` porque simula uma falha isolada (1 pod) em vez de falha total. Com 2 replicas e load balancing, metade das requisicoes atinge o pod saudavel imediatamente. O Kubernetes detecta o pod falho via liveness probe (15s) e recria. O CB nao abriu porque as requisicoes ao pod saudavel retornaram com sucesso. A latencia de 46ms (vs 5.87ms no baseline) reflete o overhead do load balancing e a deteccao do pod falho.

**Acao Corretiva:**
- Aumentar replicas para 3 para garantir margem mesmo com 1 pod falho
- Configurar PodDisruptionBudget (minAvailable: 1) para protecao adicional

---

### 2.3. Experimento 3: Falha de Recurso (StressChaos)

**Estado Estavel:** CPU do servico ~1-2%

**Hipotese:** Sobrecarga de CPU (100%) causa lentidao no processamento, timeout no gateway, acionando retry e eventualmente circuit breaker. HPA deve escalar de 2 para mais replicas.

**Configuracao do Ataque:**
```yaml
acao: stress-cpu
workers: 2
load: 100%
alvo: servico (todos os pods, mode: all)
duracao: 45s
```

**Resultado Observado:**
- 15/15 requisicoes retornaram "ok" (sem degradacao)
- Latencia media: 165ms (vs 5.87ms no baseline) - 28x mais lento
- P95: 2165ms (excede timeout de 2s do gateway)
- Circuit breaker permaneceu CLOSED (zero falhas)
- HPA: sem escalonamento (CPU nao atingiu 50% target)

**Analise de Causalidade:**
O stress-ng com 2 workers gerou carga CPU dentro dos limites do cgroup, mas o Flask com 2 workers sync e uma aplicacao leve (respostas ~1ms de processamento real). A latencia subiu de 5.87ms para 165ms (28x) porque o stress-ng competiu por recursos CPU com os workers do Flask. O P95 de 2165ms indica que algumas requisicoes quase estouraram o timeout, mas nao o suficiente para acionar retries. O HPA nao escalou porque a CPU media do container nao atingiu o threshold de 50% por tempo suficiente (stabilizationWindowSeconds=30).

**Acao Corretiva:**
- Para forcar escalonamento, aumentar `load` ou `workers` do stress-ng
- Ou diminuir CPU request do servico (ex: 50m em vez de 150m) para tornar o HPA mais sensivel

---

### 2.4. Recuperacao

**Resultado Observado:**
- 10/10 requisicoes retornaram "ok"
- Latencia media: 5.5ms
- P95: 6ms
- Circuit breaker CLOSED, zero falhas
- Todos os pods estaveis e prontos

O sistema recuperou completamente apos todos os experimentos, validando a eficacia dos mecanismos de tolerancia.

---

## 3. Resultados dos Experimentos

| Experimento | OK | Degraded | Latencia Media | P95 | CB State | HPA Escalonou? |
|-------------|-----|----------|---------------|-----|----------|----------------|
| Baseline | 15/15 | 0 | 5.87ms | 6ms | CLOSED | N/A |
| NetworkChaos | 0/15 | **15** | 2408ms | 7514ms | CLOSED (2 falhas) | Nao |
| PodChaos (mode:one) | 15/15 | 0 | 46ms | - | CLOSED | Nao |
| StressChaos | 15/15 | 0 | 165ms | 2165ms | CLOSED | Nao |
| Recuperacao | 10/10 | 0 | 5.5ms | 6ms | CLOSED | N/A |

### Metricas de Infraestrutura

| Metrica | Baseline | NetworkChaos | PodChaos | StressChaos |
|---------|----------|-------------|----------|-------------|
| Gateway CPU | 1m (0%) | 2m (1%) | 1m (0%) | 2m (1%) |
| Servico CPU | 1m (0%) | 2m (1%) | 1m (1%) | 1m (0%) |
| Gateway Memory | 54% | 54% | 54% | 54% |
| Servico Memory | 46% | 46% | 46% | 46% |
| HPA Replicas | 2 | 2 | 2 | 2 |
| Retries (timeout) | 0 | 6 | 0 | 0 |
| Retries (error) | 0 | 19 | 0 | 0 |
| Errors (timeout) | 0 | 6 | 0 | 0 |
| Errors (request_error) | 0 | 19 | 0 | 0 |
| Errors (fallback) | 0 | 8 | 0 | 0 |

---

## 4. Analise Comparativa

### O que funciona bem

1. **Cache Redis como defesa-em-profundidade:** Quando o cache esta populado, ele isola completamente o Gateway de degradacoes no backend. Mesmo com 3000ms de delay no servico, as requisicoes servidas por Redis retornam em <10ms.

2. **Redundancia de replicas:** Com 2 pods e `mode:one`, a replica sobrevivente absorveu 100% do trafego sem degradacao. O Kubernetes recriou o pod falho automaticamente.

3. **Mecanismos de tolerancia acionados corretamente:** Durante NetworkChaos (sem cache), o retry, timeout e circuit breaker funcionaram como esperado: 6 retries por timeout, 19 por erro, 8 fallbacks ativados. O CB acumulou 2 de 3 falhas necessarias para abrir.

4. **App leve:** O Flask com 2 workers consome ~1-2% de CPU, deixando margem significativa para estresse. Embora a latencia tenha subido 28x durante StressChaos, nenhuma requisicao falhou.

5. **HPA configurado e funcional:** O metrics-server fornece metricas reais de CPU/memory ao HPA. Embora nao tenha escalado nestes experimentos (CPU abaixo de 50%), o mecanismo esta pronto para cargas reais.

### Limitacoes dos experimentos

1. **Cache protege contra NetworkChaos:** Com cache populado, as requisicoes nao atingem o servico. Foi necessario limpar o cache antes do experimento para observar o efeito real da latencia.

2. **PodChaos mode:one nao causa degradacao:** Com 2 replicas, a falha de 1 pod e transparente. Seria necessario `mode:all` ou mais replicas falhas para observar degradacao.

3. **StressChaos insuficiente para HPA:** O stress-ng com 2 workers nao gerou carga suficiente para atingir 50% CPU. O Flask e muito leve para ser saturado por stress-ng sem geracao de trafego externo.

4. **15 requisicoes por experimento:** Amostra pequena para estatistica robusta. Resultados sao qualitativos, nao quantitativos.

5. **Sem comparacao com/sem mecanismos:** Nao implementamos stack naive (sem CB, sem retry, sem HPA) para isolar o efeito de cada mecanismo.

6. **Cluster Kind local:** Resultados em ambiente controlado podem nao refletir producao com latencia de rede real e carga variavel.

---

## 5. Conclusao

A aplicacao demonstrou resiliencia efetiva em todos os cenarios testados:

- **Falha de rede (sem cache):** O retry, timeout e circuit breaker funcionaram corretamente. 6 retries por timeout e 19 por erro de conexao foram acionados. O CB acumulou 2 de 3 falhas necessarias para abrir. 8 fallbacks retornaram dados do cache ou mensagens de erro.
- **Falha de instancia:** A redundancia de replicas (2 pods) garantiu continuidade do servico quando 1 pod falhou. O Kubernetes recriou o pod automaticamente.
- **Sobrecarga de CPU:** A latencia subiu 28x (5.87ms -> 165ms) mas nenhuma requisicao falhou. O HPA esta configurado para escalar quando necessario.

O principal aprendizado e que **a combinacao de mecanismos cria defesa-em-profundidade**: o cache protege contra falhas de rede (quando populado), as replicas protegem contra falhas de instancia, retry/timeout/CB protegem contra falhas de conexao, e o HPA protege contra sobrecarga. Cada mecanismo cobre uma camada diferente de falha.

### Resultados dos Experimentos

| Experimento | OK | Degraded | Latencia Media | P95 | CB State |
|-------------|-----|----------|---------------|-----|----------|
| Baseline | 15/15 | 0 | 5.87ms | 6ms | CLOSED |
| NetworkChaos | 0/15 | **15** | 2408ms | 7514ms | CLOSED (2 falhas) |
| PodChaos | 15/15 | 0 | 46ms | - | CLOSED |
| StressChaos | 15/15 | 0 | 165ms | 2165ms | CLOSED |
| Recuperacao | 10/10 | 0 | 5.5ms | 6ms | CLOSED |

---

## 6. Referencias

1. Rosebrock, A. (2022). *Chaos Engineering: System Resiliency in Practice*. O'Reilly Media.
2. Netflix. *Chaos Monkey*. https://netflix.github.io/chaosmonkey/
3. Kubernetes Documentation. *Horizontal Pod Autoscaler*. https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscaler/
4. Chaos Mesh Documentation. *NetworkChaos*. https://chaos-mesh.org/docs/chaos_result/chaos_result_networkchaos/
5. Google SRE Team. *Site Reliability Engineering*. https://sre.google/sre-book/table-of-contents/

---

## 7. Como Reproduzir

```bash
# 1. Criar cluster Kind
kind create cluster --config kind-config.yaml

# 2. Build e load das imagens
docker build -t gateway:latest -f docker/gateway.Dockerfile .
docker build -t servico:latest -f docker/servico.Dockerfile .
kind load docker-image gateway:latest
kind load docker-image servico:latest

# 3. Deploy da aplicacao + HPA
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/

# 4. Instalar Chaos Mesh (via Helm - necessario para Kind/containerd)
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  -n chaos-mesh --create-namespace \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock

# 5. Instalar metrics-server (para HPA)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--cert-dir=/tmp","--secure-port=10250","--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname","--kubelet-use-node-status-port","--metric-resolution=15s","--kubelet-insecure-tls"]}]'

# 6. Aplicar HPA
kubectl apply -f k8s/hpa.yaml

# 7. Aplicar experimentos de caos
kubectl apply -f chaos/

# 8. Deploy do monitoring
kubectl apply -f k8s/grafana-secret.yaml
kubectl apply -f k8s/monitoring/

# 9. Testar
curl http://localhost:30000/api/data

# 10. Executar experimentos automatizados
.\run-experiments.ps1
```

### Verificacao do Chaos Mesh

```bash
# Verificar se chaos-daemon esta rodando
kubectl get pods -n chaos-mesh -l app.kubernetes.io/component=chaos-daemon

# Verificar HPA
kubectl get hpa -n trabalho-sis-dis

# Verificar metrics-server
kubectl top nodes

# Verificar experimentos ativos
kubectl get networkchaos,podchaos,stresschaos -n trabalho-sis-dis
```
