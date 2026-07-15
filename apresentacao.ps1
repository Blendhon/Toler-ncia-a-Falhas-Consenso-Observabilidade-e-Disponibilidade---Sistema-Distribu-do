$ErrorActionPreference = "Continue"

$GW = "http://localhost:30000"
$PROM = "http://localhost:30090"

function Show-Header($blockNum, $total, $title) {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  BLOCO $blockNum/$total - $title" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-SubHeader($text) {
    Write-Host ""
    Write-Host "--- $text ---" -ForegroundColor Yellow
    Write-Host ""
}

function Run-Cmd($label, $scriptBlock) {
    Write-Host ">>> $label" -ForegroundColor White
    & $scriptBlock | Out-Host
    Write-Host ""
}

function Send-Load($count, $delayMs = 300) {
    $results = @()
    for ($i = 0; $i -lt $count; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-RestMethod -Uri "$GW/api/data" -TimeoutSec 10
            $sw.Stop()
            $results += @{ status = $r.status; latency_ms = $sw.ElapsedMilliseconds; source = $r.data.source }
        } catch {
            $sw.Stop()
            $results += @{ status = "error"; latency_ms = $sw.ElapsedMilliseconds }
        }
        if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
    }
    return $results
}

function Count-Results($results) {
    $ok      = ($results | Where-Object { $_.status -eq "ok" }).Count
    $degraded = ($results | Where-Object { $_.status -eq "degraded" }).Count
    $err     = ($results | Where-Object { $_.status -eq "error" }).Count
    $lats    = $results | ForEach-Object { $_.latency_ms } | Where-Object { $_ -ne $null }
    $avg     = if ($lats.Count -gt 0) { [math]::Round(($lats | Measure-Object -Average).Average, 2) } else { 0 }
    $p95     = if ($lats.Count -gt 0) { ($lats | Sort-Object)[[math]::Floor($lats.Count * 0.95)] } else { 0 }
    return @{ ok = $ok; degraded = $degraded; error = $err; total = $results.Count; avg_ms = $avg; p95_ms = $p95 }
}

function Show-Result($r) {
    $color = if ($r.degraded + $r.error -gt 0) { "Yellow" } else { "Green" }
    Write-Host "  Resultado: OK=$($r.ok) Degraded=$($r.degraded) Error=$($r.error) | Latencia=$($r.avg_ms)ms P95=$($r.p95_ms)ms" -ForegroundColor $color
}

function Show-Dash { Write-Host "--------------------------------------------" -ForegroundColor DarkGray }

# ╔══════════════════════════════════════════════════════════════╗
# ║  RESET INICIAL                                               ║
# ╚══════════════════════════════════════════════════════════════╝

Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  APRESENTACAO - SISTEMAS DISTRIBUIDOS 2026/1" -ForegroundColor Magenta
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""

Write-Host "[RESET] Removendo chaos anterior..." -ForegroundColor Yellow
kubectl delete networkchaos --all -n trabalho-sis-dis 2>$null | Out-Null
kubectl delete podchaos --all -n trabalho-sis-dis 2>$null | Out-Null
kubectl delete stresschaos --all -n trabalho-sis-dis 2>$null | Out-Null

Write-Host "[RESET] Reseta toggles do gateway..." -ForegroundColor Yellow
try {
    Invoke-RestMethod -Method POST -Uri "$GW/admin/toggle?cb=true&retry=true&timeout=true" -TimeoutSec 5 | Out-Null
} catch {
    Start-Sleep -Seconds 3
    Invoke-RestMethod -Method POST -Uri "$GW/admin/toggle?cb=true&retry=true&timeout=true" -TimeoutSec 5 | Out-Null
}

Write-Host "[RESET] Restaurando servico normal..." -ForegroundColor Yellow
try {
    Invoke-RestMethod -Method POST -Uri "$GW/admin/slow?ms=50" -TimeoutSec 5 | Out-Null
} catch {}

Write-Host "[RESET] Aguardando 10s para estabilizacao..." -ForegroundColor Yellow
Start-Sleep -Seconds 10
Write-Host "[RESET] Pronto!" -ForegroundColor Green

# ╔══════════════════════════════════════════════════════════════╗
# ║  BLOCO 1 - INTRODUCAO E STATUS                               ║
# ╚══════════════════════════════════════════════════════════════╝

Show-Header 1 7 "INTRODUCAO E STATUS"

Run-Cmd "kubectl get pods -n trabalho-sis-dis -o wide" {
    kubectl get pods -n trabalho-sis-dis -o wide
}

Run-Cmd "Invoke-RestMethod $GW/api/data" {
    try { Invoke-RestMethod -Uri "$GW/api/data" -TimeoutSec 10 | ConvertTo-Json } catch { Write-Host "ERRO: $($_.Exception.Message)" }
}

Run-Cmd "Invoke-RestMethod $GW/admin/status" {
    Invoke-RestMethod -Uri "$GW/admin/status" | ConvertTo-Json
}

Write-Host "Sistema funcionando. Todos os mecanismos ativos (CB=ON, Retry=ON, Timeout=ON)." -ForegroundColor Green
Write-Host ""

# ╔══════════════════════════════════════════════════════════════╗
# ║  BLOCO 2 - NETWORK CHAOS                                     ║
# ╚══════════════════════════════════════════════════════════════╝

Show-Header 2 7 "NETWORK CHAOS (latencia 3s + perda 30%)"

Show-SubHeader "Preparacao"
Run-Cmd "Medindo baseline (15 reqs sem ataque)..." {
    $results_bc = Send-Load -count 15 -delayMs 300
    $script:bc = Count-Results $results_bc
    Show-Result $script:bc
}

Run-Cmd "Limpando cache Redis..." {
    try { Invoke-RestMethod -Method POST -Uri "$GW/admin/flush" -TimeoutSec 5 | Out-Null; Write-Host "  Cache limpo" -ForegroundColor Green } catch { Write-Host "  Flush via gateway falhou" -ForegroundColor Yellow }
}

Show-SubHeader "Aplicando ataque de rede"
Run-Cmd "kubectl apply -f chaos/network-chaos.yaml" {
    kubectl apply -f chaos/network-chaos.yaml
}
Write-Host "  Aguardando 8s para Chaos Mesh injetar latencia..." -ForegroundColor Gray
Start-Sleep -Seconds 8

Show-SubHeader "Gerando 15 requisicoes durante ataque"
$results_nc = Send-Load -count 15 -delayMs 300
$nc = Count-Results $results_nc
Show-Result $nc

Show-SubHeader "Metricas durante ataque"
Run-Cmd "Circuit Breaker state" {
    $cbData = Invoke-RestMethod "$PROM/api/v1/query?query=gateway_circuit_breaker_state" -TimeoutSec 10 2>$null
    if ($cbData.data.result.Count -gt 0) {
        $stateMap = @{ "0" = "CLOSED"; "1" = "OPEN"; "2" = "HALF_OPEN" }
        $val = [math]::Round([double]$cbData.data.result[0].value[1])
        Write-Host "  Circuit Breaker: $($stateMap[[string]$val])" -ForegroundColor $(if ($val -eq 0) { "Green" } elseif ($val -eq 1) { "Red" } else { "Yellow" })
    }
}
Run-Cmd "Erros por tipo" {
    $errData = Invoke-RestMethod "$PROM/api/v1/query?query=sum(gateway_errors_total)by(type)" -TimeoutSec 10 2>$null
    $errData.data.result | ForEach-Object { Write-Host "  $($_.metric.type): $([math]::Round([double]$_.value[1]))" -ForegroundColor Gray }
}

Show-SubHeader "Removendo ataque e verificando recuperacao"
Run-Cmd "kubectl delete -f chaos/network-chaos.yaml" {
    kubectl delete -f chaos/network-chaos.yaml
}
Write-Host "  Aguardando 15s para recuperacao..." -ForegroundColor Gray
Start-Sleep -Seconds 15

Run-Cmd "Teste pos-recuperacao" {
    try { Invoke-RestMethod -Uri "$GW/api/data" -TimeoutSec 10 | ConvertTo-Json } catch { Write-Host "ERRO: $($_.Exception.Message)" }
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  BLOCO 3 - POD CHAOS                                         ║
# ╚══════════════════════════════════════════════════════════════╝

Show-Header 3 7 "POD CHAOS (falha de 1 pod do servico)"

Show-SubHeader "Preparacao"
Run-Cmd "Limpando cache Redis..." {
    try { Invoke-RestMethod -Method POST -Uri "$GW/admin/flush" -TimeoutSec 5 | Out-Null; Write-Host "  Cache limpo" -ForegroundColor Green } catch { Write-Host "  Flush falhou" -ForegroundColor Yellow }
}

Run-Cmd "Pods ANTES do ataque:" {
    kubectl get pods -n trabalho-sis-dis -l app=servico
}

Show-SubHeader "Aplicando pod-failure (mode:one, 30s)"
Run-Cmd "kubectl apply -f chaos/pod-chaos.yaml" {
    kubectl apply -f chaos/pod-chaos.yaml
}
Start-Sleep -Seconds 5

Run-Cmd "Pods DURANTE o ataque:" {
    kubectl get pods -n trabalho-sis-dis -l app=servico
}

Show-SubHeader "Gerando 15 requisicoes durante falha"
$results_pc = Send-Load -count 15 -delayMs 300
$pc = Count-Results $results_pc
Show-Result $pc

Show-SubHeader "Removendo ataque e verificando recuperacao"
Run-Cmd "kubectl delete -f chaos/pod-chaos.yaml" {
    kubectl delete -f chaos/pod-chaos.yaml
}
Write-Host "  Aguardando 15s para recuperacao..." -ForegroundColor Gray
Start-Sleep -Seconds 15

Run-Cmd "Pods DEPOIS da recuperacao:" {
    kubectl get pods -n trabalho-sis-dis -l app=servico
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  BLOCO 4 - STRESS CHAOS                                      ║
# ╚══════════════════════════════════════════════════════════════╝

Show-Header 4 7 "STRESS CHAOS (CPU 100%)"

Show-SubHeader "Pods antes do estresse"
Run-Cmd "Pods do servico:" {
    kubectl get pods -n trabalho-sis-dis -l app=servico
}

Show-SubHeader "Aplicando stress de CPU (mode:all, 45s)"
Run-Cmd "kubectl apply -f chaos/stress-chaos.yaml" {
    kubectl apply -f chaos/stress-chaos.yaml
}
Write-Host "  Aguardando 10s para estresse estabilizar..." -ForegroundColor Gray
Start-Sleep -Seconds 10

Show-SubHeader "Gerando 15 requisicoes durante estresse"
$results_sc = Send-Load -count 15 -delayMs 300
$sc = Count-Results $results_sc
Show-Result $sc

Show-SubHeader "Verificando HPA"
Run-Cmd "kubectl get hpa -n trabalho-sis-dis" {
    kubectl get hpa -n trabalho-sis-dis
}

Show-SubHeader "Removendo stress"
Run-Cmd "kubectl delete -f chaos/stress-chaos.yaml" {
    kubectl delete -f chaos/stress-chaos.yaml
}
Write-Host "  Aguardando 15s para recuperacao..." -ForegroundColor Gray
Start-Sleep -Seconds 15

# ╔══════════════════════════════════════════════════════════════╗
# ║  BLOCO 5 - RECUPERACAO FINAL                                 ║
# ╚══════════════════════════════════════════════════════════════╝

Show-Header 5 7 "RECUPERACAO FINAL"

Show-SubHeader "Enviando 10 requisicoes de verificacao"
$results_final = Send-Load -count 10 -delayMs 300
$final = Count-Results $results_final
Show-Result $final

Run-Cmd "Status final do Circuit Breaker:" {
    Invoke-RestMethod -Uri "$GW/admin/status" | ConvertTo-Json
}

if ($final.degraded + $final.error -eq 0) {
    Write-Host "  SISTEMA RECUPERADO COMPLETAMENTE" -ForegroundColor Green
} else {
    Write-Host "  RECUPERACAO PARCIAL" -ForegroundColor Yellow
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  BLOCO 6 - DEMO TOGGLES                                      ║
# ╚══════════════════════════════════════════════════════════════╝

Show-Header 6 7 "DEMO TOGGLES (sistema anti-falhas)"

Show-SubHeader "Passo 1: DESLIGAR todos os mecanismos"
Run-Cmd "Desativando CB + Retry + Timeout..." {
    Invoke-RestMethod -Method POST -Uri "$GW/admin/toggle?cb=false&retry=false&timeout=false" | ConvertTo-Json
}

Show-SubHeader "Passo 2: Tornar servico lento (3000ms)"
Run-Cmd "Definindo delay=3000ms..." {
    Invoke-RestMethod -Method POST -Uri "$GW/admin/slow?ms=3000" | Out-Null
    Write-Host "  Servico agora com 3000ms de delay" -ForegroundColor Red
}

Show-SubHeader "Passo 3: Teste SEM nenhum mecanismo"
Run-Cmd "Limpando cache Redis..." {
    try { Invoke-RestMethod -Method POST -Uri "$GW/admin/flush" -TimeoutSec 5 | Out-Null; Write-Host "  Cache limpo" -ForegroundColor Green } catch { Write-Host "  Flush falhou" -ForegroundColor Yellow }
}
Write-Host "  (deve demorar ~3s e retornar OK -- sem timeout nem retry)" -ForegroundColor Gray
$sw1 = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $r1 = Invoke-RestMethod -Uri "$GW/api/data" -TimeoutSec 15
    $sw1.Stop()
    Write-Host "  Status: $($r1.status) | Latencia: $($sw1.ElapsedMilliseconds)ms" -ForegroundColor Yellow
} catch {
    $sw1.Stop()
    Write-Host "  ERRO: $($_.Exception.Message) | Latencia: $($sw1.ElapsedMilliseconds)ms" -ForegroundColor Red
}

Show-SubHeader "Passo 4: LIGAR Retry"
Run-Cmd "Ativando Retry..." {
    Invoke-RestMethod -Method POST -Uri "$GW/admin/toggle?retry=true" | ConvertTo-Json
}
Run-Cmd "Limpando cache Redis..." {
    try { Invoke-RestMethod -Method POST -Uri "$GW/admin/flush" -TimeoutSec 5 | Out-Null; Write-Host "  Cache limpo" -ForegroundColor Green } catch {}
}
Write-Host "  (3 tentativas x ~3s cada = ~9s total, sem timeout)" -ForegroundColor Gray
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $r2 = Invoke-RestMethod -Uri "$GW/api/data" -TimeoutSec 20
    $sw2.Stop()
    Write-Host "  Status: $($r2.status) | Latencia: $($sw2.ElapsedMilliseconds)ms" -ForegroundColor Yellow
} catch {
    $sw2.Stop()
    Write-Host "  ERRO: $($_.Exception.Message) | Latencia: $($sw2.ElapsedMilliseconds)ms" -ForegroundColor Yellow
}

Show-SubHeader "Passo 5: LIGAR Timeout"
Run-Cmd "Ativando Timeout (2s)..." {
    Invoke-RestMethod -Method POST -Uri "$GW/admin/toggle?timeout=true" | ConvertTo-Json
}
Run-Cmd "Limpando cache Redis..." {
    try { Invoke-RestMethod -Method POST -Uri "$GW/admin/flush" -TimeoutSec 5 | Out-Null; Write-Host "  Cache limpo" -ForegroundColor Green } catch {}
}
Write-Host "  (max 6s -- 3 tentativas x 2s timeout -- retorna degraded)" -ForegroundColor Gray
$sw3 = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $r3 = Invoke-RestMethod -Uri "$GW/api/data" -TimeoutSec 15
    $sw3.Stop()
    Write-Host "  Status: $($r3.status) | Latencia: $($sw3.ElapsedMilliseconds)ms" -ForegroundColor Yellow
} catch {
    $sw3.Stop()
    Write-Host "  ERRO: $($_.Exception.Message) | Latencia: $($sw3.ElapsedMilliseconds)ms" -ForegroundColor Yellow
}

Show-SubHeader "Passo 6: LIGAR Circuit Breaker (sistema completo)"
Run-Cmd "Ativando Circuit Breaker..." {
    Invoke-RestMethod -Method POST -Uri "$GW/admin/toggle?cb=true" | ConvertTo-Json
}
Run-Cmd "Limpando cache Redis..." {
    try { Invoke-RestMethod -Method POST -Uri "$GW/admin/flush" -TimeoutSec 5 | Out-Null; Write-Host "  Cache limpo" -ForegroundColor Green } catch {}
}
Write-Host "  (3 falhas consecutivas -> CB abre -> respostas instantaneas)" -ForegroundColor Gray
for ($i = 0; $i -lt 5; $i++) {
    $sw4 = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r4 = Invoke-RestMethod -Uri "$GW/api/data" -TimeoutSec 10
        $sw4.Stop()
        Write-Host "  Req $($i+1): Status=$($r4.status) Latencia=$($sw4.ElapsedMilliseconds)ms" -ForegroundColor $(if ($sw4.ElapsedMilliseconds -lt 200) { "Green" } else { "Yellow" })
    } catch {
        $sw4.Stop()
        Write-Host "  Req $($i+1): ERRO Latencia=$($sw4.ElapsedMilliseconds)ms" -ForegroundColor Red
    }
    Start-Sleep -Milliseconds 500
}

Run-Cmd "Estado do CB apos 5 requisicoes:" {
    $status = Invoke-RestMethod -Uri "$GW/admin/status"
    Write-Host "  CB: $($status.cb_state) | Retry: $($status.retry) | Timeout: $($status.timeout)" -ForegroundColor $(if ($status.cb_state -eq "OPEN") { "Red" } else { "Green" })
}

Show-SubHeader "Passo 7: Restaurar sistema"
Run-Cmd "Restaurando servico (50ms) e toggles..." {
    Invoke-RestMethod -Method POST -Uri "$GW/admin/slow?ms=50" | Out-Null
    Invoke-RestMethod -Method POST -Uri "$GW/admin/toggle?cb=true&retry=true&timeout=true" | Out-Null
    Write-Host "  Aguardando 12s para CB ir para HALF_OPEN -> CLOSED..." -ForegroundColor Gray
}
Start-Sleep -Seconds 12

Run-Cmd "Teste final apos restauracao:" {
    try { Invoke-RestMethod -Uri "$GW/api/data" -TimeoutSec 10 | ConvertTo-Json } catch { Write-Host "ERRO" }
}

Run-Cmd "Status final:" {
    Invoke-RestMethod -Uri "$GW/admin/status" | ConvertTo-Json
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  BLOCO 7 - MONITORING                                        ║
# ╚══════════════════════════════════════════════════════════════╝

Show-Header 7 7 "MONITORING (Grafana + Prometheus)"

Write-Host "  Para acessar os dashboards:" -ForegroundColor White
Write-Host "  Grafana:     http://localhost:30030  (admin / admin)" -ForegroundColor Cyan
Write-Host "  Prometheus:  http://localhost:30090" -ForegroundColor Cyan
Write-Host ""
Write-Host "  O dashboard 'Sistema Distribuido - Visao Geral' abre automaticamente." -ForegroundColor Gray
Write-Host ""

Run-Cmd "Abrindo port-forward Grafana (Terminal 2)..." {
    Start-Process powershell -ArgumentList "-Command", "cd '$PSScriptRoot'; kubectl port-forward -n trabalho-sis-dis svc/grafana 30030:3000" -WindowStyle Normal
    Write-Host "  Grafana aberto em nova janela" -ForegroundColor Green
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  RESUMO FINAL                                                ║
# ╚══════════════════════════════════════════════════════════════╝

Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  RESUMO DOS EXPERIMENTOS" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Baseline:      OK=$($bc.ok)/15 Deg=$($bc.degraded) Err=$($bc.error) | LatMedia=$($bc.avg_ms)ms" -ForegroundColor White
Write-Host "  NetworkChaos:  OK=$($nc.ok)/15 Deg=$($nc.degraded) Err=$($nc.error) | LatMedia=$($nc.avg_ms)ms" -ForegroundColor White
Write-Host "  PodChaos:      OK=$($pc.ok)/15 Deg=$($pc.degraded) Err=$($pc.error) | LatMedia=$($pc.avg_ms)ms" -ForegroundColor White
Write-Host "  StressChaos:   OK=$($sc.ok)/15 Deg=$($sc.degraded) Err=$($sc.error) | LatMedia=$($sc.avg_ms)ms" -ForegroundColor White
Write-Host "  Recuperacao:   OK=$($final.ok)/10 Deg=$($final.degraded) Err=$($final.error) | LatMedia=$($final.avg_ms)ms" -ForegroundColor White
Write-Host ""
Write-Host "  Mecanismos de tolerancia a falhas:" -ForegroundColor Cyan
Write-Host "    Circuit Breaker: 3 falhas -> OPEN, recovery 10s" -ForegroundColor Gray
Write-Host "    Retry:           3 tentativas, backoff linear 0.5s*attempt" -ForegroundColor Gray
Write-Host "    Timeout:         2s por request" -ForegroundColor Gray
Write-Host "    Replicas:        2 pods (HPA min=2 max=5)" -ForegroundColor Gray
Write-Host "    Cache Redis:     TTL 30s" -ForegroundColor Gray
Write-Host ""
Write-Host "  Limpeza: kind delete cluster" -ForegroundColor Gray
Write-Host "============================================" -ForegroundColor Magenta
