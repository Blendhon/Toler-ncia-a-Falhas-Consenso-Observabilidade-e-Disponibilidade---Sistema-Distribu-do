# Comandos — Trabalho Sistemas Distribuídos

## Terminal 1: Setup (PowerShell no diretório do projeto)

```powershell
cd "C:\...\Trab Sis Dis"

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\setup.ps1
```

## Terminal 2: Testes com o sistema

```powershell
curl.exe -s http://localhost:30000/api/data
Invoke-RestMethod -Uri "http://localhost:30000/api/data" -TimeoutSec 10 | ConvertTo-Json

for ($i=1; $i -le 15; $i++) {
    Write-Host "--- Requisição $i ---" -ForegroundColor Cyan
    Invoke-RestMethod -Uri "http://localhost:30000/api/data" -TimeoutSec 10 | ConvertTo-Json
    Start-Sleep -Seconds 2
}
```

## Terminal 3: Logs e monitoramento

```powershell
kubectl logs -n trabalho-sis-dis -l app=gateway --tail=50 -f
kubectl logs -n trabalho-sis-dis -l app=servico --tail=50 -f
kubectl get pods -n trabalho-sis-dis -w
kubectl get networkchaos,podchaos,stresschaos -n trabalho-sis-dis
```

## Comandos avulsos

```powershell
kubectl port-forward -n trabalho-sis-dis svc/gateway 30000:5000
kubectl apply -f chaos/
kubectl delete -f chaos/
kubectl delete pod -n trabalho-sis-dis -l app=servico
kubectl scale deploy -n trabalho-sis-dis gateway --replicas=3
kubectl scale deploy -n trabalho-sis-dis servico --replicas=3
kubectl exec -n trabalho-sis-dis -it deploy/gateway -- sh
kind delete cluster --name kind
```

## Fluxo de teste recomendado

| Passo | Ação | Terminal |
|-------|------|----------|
| 1 | `.\setup.ps1` -> opção **1** (NetworkChaos) | 1 |
| 2 | `kubectl logs ... gateway ... -f` | 3 |
| 3 | Bateria de 15 requisições | 2 |
| 4 | Analisar timeouts + circuit breaker + recuperação | - |
| 5 | `.\setup.ps1` -> opção **2** (PodChaos) | 1 |
| 6 | Repetir testes e observar pod kill + recriação | 2+3 |
| 7 | `.\setup.ps1` -> opção **3** (StressChaos) | 1 |
| 8 | Repetir testes e observar lentidão por CPU | 2+3 |
| 9 | `kubectl get networkchaos,podchaos,stresschaos -n trabalho-sis-dis` | qqr |
```