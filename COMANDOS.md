# Comandos — Trabalho Sistemas Distribuídos

## Passo a Passo Completo

### 1. Setup (Terminal 1)

```powershell
cd "C:\Users\blend\OneDrive\Área de Trabalho\Trab Sis Dis"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\setup.ps1
```

Cria cluster Kind, build das imagens Docker, deploy da aplicação (gateway, servico, Redis), Chaos Mesh (configurado para containerd), e stack de monitoramento (Prometheus, Grafana, Redis Exporter). Demora ~3-4 minutos.

#### Verificação do Chaos Mesh

```powershell
# Verificar se chaos-daemon está rodando
kubectl get pods -n chaos-mesh -l app.kubernetes.io/component=chaos-daemon

# Verificar socket containerd
docker exec kind-control-plane ls -la /run/containerd/containerd.sock
```

### 2. Verificar pods (Terminal 1 ou 2)

```powershell
kubectl get pods -n trabalho-sis-dis
```

Todos os pods devem estar `Running` e `READY 1/1`.

### 3. Teste rápido

```powershell
Invoke-RestMethod -Uri "http://localhost:30000/api/data" -TimeoutSec 10 | ConvertTo-Json
```

Deve retornar JSON com `"status": "ok"`.

### 4. Rodar experimentos de caos

```powershell
.\run-experiments.ps1
```

Executa 5 fases automaticamente:
- **Baseline**: 15 reqs sem ataque
- **NetworkChaos**: latência 3s + perda 30% (mode: all, duration: 300s)
- **PodChaos**: falha de todos os pods do servico (mode: all, duration: 30s)
- **StressChaos**: CPU 100% (mode: all, duration: 45s)
- **Recuperação**: 10 reqs verificando normalização

Gera `monitoring-report.json` com todos os dados.

#### Verificação de cada experimento

```powershell
# Verificar chaos ativo
kubectl get networkchaos,podchaos,stresschaos -n trabalho-sis-dis

# Verificar detalhes do experimento
kubectl describe networkchaos network-delay-servico -n trabalho-sis-dis

# Verificar métricas durante o experimento
Invoke-RestMethod "http://localhost:30090/api/v1/query?query=gateway_circuit_breaker_state"
Invoke-RestMethod "http://localhost:30090/api/v1/query?query=sum(gateway_errors_total)by(type)"
```

### 5. Ver resultado do relatório

```powershell
Get-Content monitoring-report.json -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 10
```

### 6. Menu interativo de demo (Terminal 2)

```powershell
.\setup-demo.ps1
```

Menu para aplicar/remover chaos individualmente, toggles do sistema anti-falhas, ver métricas. **Fechar este terminal antes de rodar `run-experiments.ps1`** para evitar conflito de toggles.

### 7. Acessar dashboards de monitoramento

```powershell
# Prometheus (Terminal 3)
kubectl port-forward -n trabalho-sis-dis svc/prometheus 30090:9090
# Abrir: http://localhost:30090

# Grafana - admin/admin (Terminal 4)
kubectl port-forward -n trabalho-sis-dis svc/grafana 30030:3000
# Abrir: http://localhost:30030
```

### 8. Limpar tudo ao final

```powershell
kind delete cluster
```

---

## Fluxo de Teste Recomendado

| Passo | Ação | Terminal |
|-------|------|----------|
| 1 | `.\setup.ps1` | 1 |
| 2 | `kubectl get pods -n trabalho-sis-dis` — confirmar todos Running | 2 |
| 3 | `.\run-experiments.ps1` — executar os 5 experimentos | 2 |
| 4 | Analisar `monitoring-report.json` | - |
| 5 | `.\setup-demo.ps1` — explorar toggles e chaos individual | 3 |
| 6 | Port-forward Prometheus/Grafana — visualizar métricas | 4 |

---

## Comandos Avulsos

### Gerenciamento de pods
```powershell
kubectl get pods -n trabalho-sis-dis -w
kubectl get pods -n trabalho-sis-dis -o wide
kubectl logs -n trabalho-sis-dis -l app=gateway --tail=50 -f
kubectl logs -n trabalho-sis-dis -l app=servico --tail=50 -f
kubectl delete pod -n trabalho-sis-dis -l app=servico
kubectl scale deploy -n trabalho-sis-dis gateway --replicas=3
kubectl scale deploy -n trabalho-sis-dis servico --replicas=3
```

### Gerenciamento de chaos
```powershell
kubectl get networkchaos,podchaos,stresschaos -n trabalho-sis-dis
kubectl apply -f chaos/
kubectl delete -f chaos/
kubectl delete networkchaos --all -n trabalho-sis-dis
```

### Acesso direto
```powershell
kubectl port-forward -n trabalho-sis-dis svc/gateway 30000:5000
kubectl exec -n trabalho-sis-dis -it deploy/gateway -- sh
```

---

## Comandos de Demo (Toggle Anti-Falhas)

### Verificar status atual
```powershell
Invoke-RestMethod -Uri "http://localhost:30000/admin/status" | ConvertTo-Json
```

### DESLIGAR todos os mecanismos (mostrar erros)
```powershell
Invoke-RestMethod -Method POST -Uri "http://localhost:30000/admin/toggle?cb=false&retry=false&timeout=false"
```

### LIGAR apenas Retry
```powershell
Invoke-RestMethod -Method POST -Uri "http://localhost:30000/admin/toggle?retry=true"
```

### LIGAR Retry + Timeout
```powershell
Invoke-RestMethod -Method POST -Uri "http://localhost:30000/admin/toggle?retry=true&timeout=true"
```

### LIGAR todos (sistema resiliente)
```powershell
Invoke-RestMethod -Method POST -Uri "http://localhost:30000/admin/toggle?cb=true&retry=true&timeout=true"
```

### Limpar cache Redis
```powershell
Invoke-RestMethod -Method POST -Uri "http://localhost:30000/admin/flush"
```

### Simular serviço lento (3000ms)
```powershell
Invoke-RestMethod -Method POST -Uri "http://localhost:30000/admin/slow?ms=3000"
```

### Restaurar serviço normal (50ms)
```powershell
Invoke-RestMethod -Method POST -Uri "http://localhost:30000/admin/slow?ms=50"
```

### Fluxo da demonstração interativa

| Passo | Comando | O que mostrar |
|-------|---------|---------------|
| 1 | `toggle?cb=false&retry=false&timeout=false` | Sistema sem proteção |
| 2 | `Invoke-RestMethod ... /api/data` | Erros diretos, sem retry |
| 3 | `toggle?retry=true` | Liga retry |
| 4 | `Invoke-RestMethod ... /api/data` | Retry aciona, mas eventualmente falha |
| 5 | `toggle?timeout=true` | Liga timeout |
| 6 | `Invoke-RestMethod ... /api/data` | Timeout + retry, circuit breaker pode abrir |
| 7 | `toggle?cb=true` | Liga circuit breaker |
| 8 | `Invoke-RestMethod ... /api/data` | Sistema completo, degrada elegantemente |

---

## Observabilidade (Prometheus + Grafana)

### Métricas via API do Prometheus

```powershell
# Request rate do gateway
Invoke-RestMethod "http://localhost:30090/api/v1/query?query=sum(rate(gateway_requests_total[1m]))by(status)"

# Latencia media do gateway
Invoke-RestMethod "http://localhost:30090/api/v1/query?query=rate(gateway_request_duration_seconds_sum[1m])/rate(gateway_request_duration_seconds_count[1m])"

# Estado do circuit breaker
Invoke-RestMethod "http://localhost:30090/api/v1/query?query=gateway_circuit_breaker_state"

# Cache hit rate do servico
Invoke-RestMethod "http://localhost:30090/api/v1/query?query=rate(servico_cache_hits_total[1m])/(rate(servico_cache_hits_total[1m])+rate(servico_cache_misses_total[1m]))"

# Retries por resultado
Invoke-RestMethod "http://localhost:30090/api/v1/query?query=sum(rate(gateway_retries_total[1m]))by(result)"

# Erros por tipo
Invoke-RestMethod "http://localhost:30090/api/v1/query?query=sum(gateway_errors_total)by(type)"

# CPU dos containers
Invoke-RestMethod "http://localhost:30090/api/v1/query?query=rate(container_cpu_usage_seconds_total{namespace='trabalho-sis-dis'}[1m])"

# Memoria dos containers
Invoke-RestMethod "http://localhost:30090/api/v1/query?query=container_memory_working_set_bytes{namespace='trabalho-sis-dis'}"

# Metricas Redis (via exporter)
Invoke-RestMethod "http://localhost:30090/api/v1/query?query=redis_connected_clients"
Invoke-RestMethod "http://localhost:30090/api/v1/query?query=rate(redis_commands_processed_total[1m])"
```

### Endpoints de métricas da aplicação

```powershell
# Métricas brutas do gateway
curl.exe http://localhost:30000/metrics

# Métricas brutas do servico (via port-forward)
kubectl port-forward -n trabalho-sis-dis svc/servico 5001:5001
curl.exe http://localhost:5001/metrics
```

---

## Solução de Problemas

### Chaos Mesh não aplica latência

**Causa**: Chaos Mesh estava configurado para Docker, mas Kind usa containerd.

**Verificar**:
```powershell
# Verificar se chaos-daemon está rodando
kubectl get pods -n chaos-mesh -l app.kubernetes.io/component=chaos-daemon

# Verificar socket
docker exec kind-control-plane ls -la /run/containerd/containerd.sock
```

**Fix já aplicado** em `setup.ps1`:
```powershell
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --create-namespace `
  --set chaosDaemon.runtime=containerd `
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock
```

### NetworkChaos preso durante delete (finalizers)

```powershell
# Verificar se há recursos presos
kubectl get networkchaos -n trabalho-sis-dis

# Se preso, remover finalizers
$json = kubectl get networkchaos <nome> -n trabalho-sis-dis -o json
$obj = $json | ConvertFrom-Json
$obj.metadata.finalizers = @()
$obj | ConvertTo-Json -Depth 20 | kubectl replace -f -
```

### Redis indisponível no boot dos pods

**Causa**: Gateway/Servico tentavam conectar ao Redis no import do módulo.

**Fix já aplicado**: Redis agora usa lazy init com retry (3 tentativas, 2s cada) em `gateway/app.py` e `servico/app.py`.

### Toggle reset entre sessões

O Redis preserva toggles entre sessões. O `run-experiments.ps1` reseta toggles automaticamente antes de iniciar. Feche o `setup-demo.ps1` antes de rodar experimentos.
