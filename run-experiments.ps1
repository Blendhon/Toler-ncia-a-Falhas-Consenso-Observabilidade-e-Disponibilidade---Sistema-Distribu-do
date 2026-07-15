$ErrorActionPreference = "Continue"
$PROM = "http://localhost:30090"
$GW = "http://localhost:30000"
$report = @{ timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); experiments = @() }

function Get-Prometheus($query) {
    try {
        $r = Invoke-RestMethod -Uri "$PROM/api/v1/query?query=$([System.Uri]::EscapeDataString($query))" -TimeoutSec 10
        return $r.data.result
    } catch { return @() }
}

function Send-Load($count, $delayMs=300) {
    $results = @()
    for ($i=0; $i -lt $count; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-RestMethod -Uri "$GW/api/data" -TimeoutSec 10
            $sw.Stop()
            $results += @{ status=$r.status; latency_ms=$sw.ElapsedMilliseconds; source=$r.data.source }
        } catch {
            $sw.Stop()
            $results += @{ status="error"; latency_ms=$sw.ElapsedMilliseconds; error=$_.Exception.Message }
        }
        Start-Sleep -Milliseconds $delayMs
    }
    return $results
}

function Count-Results($results) {
    $ok = ($results | Where-Object { $_.status -eq "ok" }).Count
    $degraded = ($results | Where-Object { $_.status -eq "degraded" }).Count
    $err = ($results | Where-Object { $_.status -eq "error" }).Count
    $lats = $results | ForEach-Object { $_.latency_ms } | Where-Object { $_ -ne $null }
    $avg = if ($lats.Count -gt 0) { [math]::Round(($lats | Measure-Object -Average).Average, 2) } else { 0 }
    $p95 = if ($lats.Count -gt 0) {
        $sorted = $lats | Sort-Object
        $sorted[[math]::Floor($sorted.Count * 0.95)]
    } else { 0 }
    return @{ ok=$ok; degraded=$degraded; error=$err; total=$results.Count; avg_ms=$avg; p95_ms=$p95 }
}

function Get-SystemMetrics {
    $cbState = Get-Prometheus "gateway_circuit_breaker_state"
    $cbFail = Get-Prometheus "gateway_circuit_breaker_failures"
    $gwErr = Get-Prometheus "sum(gateway_errors_total) by (type)"
    $gwRetry = Get-Prometheus "sum(gateway_retries_total) by (result)"
    $gwFwd = Get-Prometheus "sum(gateway_forward_requests_total) by (status)"
    $cbStateVal = if ($cbState.Count -gt 0) { [math]::Round([double]$cbState[0].value[1]) } else { -1 }
    $cbStateMap = @{ "-1"="unknown"; "0"="CLOSED"; "1"="OPEN"; "2"="HALF_OPEN" }
    return @{
        circuit_breaker_state = $cbStateMap[[string]$cbStateVal]
        circuit_breaker_failures = if ($cbFail.Count -gt 0) { [double]$cbFail[0].value[1] } else { 0 }
        gateway_errors = $gwErr | ForEach-Object { @{ type=$_.metric.type; count=[double]$_.value[1] } }
        gateway_retries = $gwRetry | ForEach-Object { @{ result=$_.metric.result; count=[double]$_.value[1] } }
        gateway_forwards = $gwFwd | ForEach-Object { @{ status=$_.metric.status; count=[double]$_.value[1] } }
    }
}

function Get-PodStatus {
    $json = kubectl get pods -n trabalho-sis-dis -o json 2>$null
    if (-not $json) { return @() }
    $pods = $json | ConvertFrom-Json
    if (-not $pods.items) { return @() }
    $pods.items | ForEach-Object {
        $restarts = 0
        if ($_.status.containerStatuses -and $_.status.containerStatuses.Count -gt 0) {
            $restarts = $_.status.containerStatuses[0].restartCount
        }
        @{ name=$_.metadata.name; status=$_.status.phase; restarts=$restarts; app=$_.metadata.labels.app }
    }
}

function Get-HPAStatus {
    $json = kubectl get hpa -n trabalho-sis-dis -o json 2>$null
    if (-not $json) { return @() }
    $hpas = $json | ConvertFrom-Json
    if (-not $hpas.items) { return @() }
    $hpas.items | ForEach-Object {
        $current = 0
        $desired = 0
        if ($_.status.currentReplicas) { $current = $_.status.currentReplicas }
        if ($_.status.desiredReplicas) { $desired = $_.status.desiredReplicas }
        @{
            name=$_.metadata.name
            current_replicas=$current
            desired_replicas=$desired
            min=$_.spec.minReplicas
            max=$_.spec.maxReplicas
            targets=$_.status.currentMetrics
        }
    }
}

function Get-PodCountByApp {
    $pods = Get-PodStatus
    $gw = ($pods | Where-Object { $_.app -eq "gateway" }).Count
    $sv = ($pods | Where-Object { $_.app -eq "servico" }).Count
    return @{ gateway=$gw; servico=$sv; total=$pods.Count }
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  CHAOS + MONITORAMENTO + HPA" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "  PodChaos:mode:one | 15 reqs/expo | HPA:min=2,max=5 | Cache flush antes de cada expo" -ForegroundColor Gray
Write-Host "============================================" -ForegroundColor Cyan

# ═══ RESET TOGGLES (Redis preserva estado entre sessoes) ═══
Write-Host "`n[SETUP] Resetando toggles do gateway..." -ForegroundColor Yellow
try {
    Invoke-RestMethod -Method POST -Uri "$GW/admin/toggle?cb=true&retry=true&timeout=true" -TimeoutSec 5 | Out-Null
    Write-Host "  Toggles resetados: CB=ON Retry=ON Timeout=ON" -ForegroundColor Green
} catch {
    Write-Host "  Nao foi possivel acessar gateway, aguardando 5s..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    Invoke-RestMethod -Method POST -Uri "$GW/admin/toggle?cb=true&retry=true&timeout=true" -TimeoutSec 5 | Out-Null
    Write-Host "  Toggles resetados" -ForegroundColor Green
}

# ═══ VERIFICAR CHAOS MESH ═══
Write-Host "`n[SETUP] Verificando Chaos Mesh..." -ForegroundColor Yellow
$daemonCount = (kubectl get pods -n chaos-mesh -l app.kubernetes.io/component=chaos-daemon --no-headers 2>$null | Measure-Object -Line).Lines
if ($daemonCount -eq 0) {
    Write-Host "  [ERRO] Chaos Daemon nao esta rodando. Verificando pods:" -ForegroundColor Red
    kubectl get pods -n chaos-mesh
    exit 1
}
Write-Host "  Chaos Mesh OK ($daemonCount daemon(s) rodando)" -ForegroundColor Green

# ═══ VERIFICAR HPA ═══
Write-Host "`n[SETUP] Verificando HPA..." -ForegroundColor Yellow
$hpaList = Get-HPAStatus
if ($hpaList.Count -eq 0) {
    Write-Host "  [AVISO] HPA nao encontrado. Metrics-server pode nao estar pronto." -ForegroundColor Yellow
} else {
    foreach ($h in $hpaList) {
        Write-Host "  $($h.name): current=$($h.current_replicas) desired=$($h.desired_replicas) min=$($h.min) max=$($h.max)" -ForegroundColor Green
    }
}

# ═══ BASELINE ═══
Write-Host "`n[BASELINE] 15 requisicoes sem ataque..." -ForegroundColor Yellow
$prePods = Get-PodCountByApp
$baselineResults = Send-Load -count 15 -delayMs 300
Start-Sleep -Seconds 3
$baselineMetrics = Get-SystemMetrics
$baselinePods = Get-PodStatus
$baselineHPA = Get-HPAStatus
$bc = Count-Results $baselineResults

$report.experiments += @{
    phase = "baseline"; description = "Estado estavel - sem ataque"
    config = "N/A"
    request_results = $bc
    metrics = $baselineMetrics; pods = $baselinePods; hpa = $baselineHPA
    pod_counts_before = $prePods
}
Write-Host "  OK=$($bc.ok) Degraded=$($bc.degraded) Error=$($bc.error) Latencia=$($bc.avg_ms)ms P95=$($bc.p95_ms)ms" -ForegroundColor $(if ($bc.degraded + $bc.error -gt 0) { "Yellow" } else { "Green" })
Write-Host "  CB=$($baselineMetrics.circuit_breaker_state) Failures=$($baselineMetrics.circuit_breaker_failures)" -ForegroundColor Green
Write-Host "  Pods: Gateway=$($prePods.gateway) Servico=$($prePods.servico)" -ForegroundColor Gray

# ═══ NETWORK CHAOS ═══
Write-Host "`n[NETWORK CHAOS] Aplicando latencia 3s + perda 30% (mode:all)..." -ForegroundColor Yellow
Write-Host "  Limpando cache Redis para forcar requests ao servico..." -ForegroundColor Cyan
try {
    Invoke-RestMethod -Method POST -Uri "$GW/admin/flush" -TimeoutSec 5 | Out-Null
    Write-Host "  Cache limpo!" -ForegroundColor Green
} catch {
    Write-Host "  Flush via gateway falhou, tentando direto no Redis..." -ForegroundColor Yellow
    kubectl exec -n trabalho-sis-dis redis-55f8784fcf-ntcjb -- redis-cli FLUSHALL 2>$null
}
Start-Sleep -Seconds 2
kubectl apply -f chaos/network-chaos.yaml 2>$null | Out-Null
Start-Sleep -Seconds 8

Write-Host "  Gerando 15 requisicoes durante ataque (sem cache)..." -ForegroundColor Cyan
$ncResults = Send-Load -count 15 -delayMs 300
Start-Sleep -Seconds 3
$ncMetrics = Get-SystemMetrics
$ncPods = Get-PodStatus
$ncHPA = Get-HPAStatus
$nc = Count-Results $ncResults

$report.experiments += @{
    phase = "network_chaos"; description = "Falha de rede - latencia 3000ms + perda 30%"
    config = @{ latency="3000ms"; jitter="500ms"; correlation="50%"; loss="30%"; duration="300s"; mode="all" }
    request_results = $nc
    metrics = $ncMetrics; pods = $ncPods; hpa = $ncHPA
}
Write-Host "  OK=$($nc.ok) Degraded=$($nc.degraded) Error=$($nc.error) Latencia=$($nc.avg_ms)ms P95=$($nc.p95_ms)ms" -ForegroundColor $(if ($nc.degraded + $nc.error -gt 0) { "Red" } else { "Green" })
Write-Host "  CB=$($ncMetrics.circuit_breaker_state) Failures=$($ncMetrics.circuit_breaker_failures)" -ForegroundColor $(if ($ncMetrics.circuit_breaker_state -eq "OPEN") { "Red" } else { "Green" })

Write-Host "  Removendo NetworkChaos (15s recuperacao)..." -ForegroundColor Yellow
kubectl delete -f chaos/network-chaos.yaml 2>$null | Out-Null
Start-Sleep -Seconds 15

# ═══ POD CHAOS (mode:one - 1 pod por vez) ═══
Write-Host "`n[POD CHAOS] Falha de 1 pod do servico (mode:one, 30s)..." -ForegroundColor Yellow
Write-Host "  Limpando cache Redis..." -ForegroundColor Cyan
try {
    Invoke-RestMethod -Method POST -Uri "$GW/admin/flush" -TimeoutSec 5 | Out-Null
} catch {
    kubectl exec -n trabalho-sis-dis redis-55f8784fcf-ntcjb -- redis-cli FLUSHALL 2>$null
}
Start-Sleep -Seconds 2
$prePods = Get-PodCountByApp
$prePodStatus = Get-PodStatus
kubectl apply -f chaos/pod-chaos.yaml 2>$null | Out-Null
Start-Sleep -Seconds 3

Write-Host "  Gerando 15 requisicoes durante falha..." -ForegroundColor Cyan
$pcResults = Send-Load -count 15 -delayMs 300
Start-Sleep -Seconds 8
$pcMetrics = Get-SystemMetrics
$pcPods = Get-PodStatus
$pcHPA = Get-HPAStatus
$pc = Count-Results $pcResults
$postPods = Get-PodCountByApp

$report.experiments += @{
    phase = "pod_chaos"; description = "Falha de instancia - 1 pod do servico (mode:one)"
    config = @{ action="pod-failure"; mode="one"; target="servico"; duration="30s" }
    request_results = $pc
    metrics = $pcMetrics; pods_before=$prePodStatus; pods_after=$pcPods; hpa=$pcHPA
    pod_counts_before = $prePods; pod_counts_after = $postPods
}
Write-Host "  OK=$($pc.ok) Degraded=$($pc.degraded) Error=$($pc.error) Latencia=$($pc.avg_ms)ms" -ForegroundColor $(if ($pc.degraded + $pc.error -gt 0) { "Yellow" } else { "Green" })
Write-Host "  CB=$($pcMetrics.circuit_breaker_state)" -ForegroundColor Green
Write-Host "  Pods antes: Gateway=$($prePods.gateway) Servico=$($prePods.servico) | Depois: Gateway=$($postPods.gateway) Servico=$($postPods.servico)" -ForegroundColor Gray

Write-Host "  Removendo PodChaos (15s recuperacao)..." -ForegroundColor Yellow
kubectl delete -f chaos/pod-chaos.yaml 2>$null | Out-Null
Start-Sleep -Seconds 15

# ═══ STRESS CHAOS (com HPA) ═══
Write-Host "`n[STRESS CHAOS] CPU 100% em todos os pods (mode:all, 45s)..." -ForegroundColor Yellow
Write-Host "  Monitorando escalonamento do HPA..." -ForegroundColor Cyan
$preStressPods = Get-PodCountByApp
kubectl apply -f chaos/stress-chaos.yaml 2>$null | Out-Null
Start-Sleep -Seconds 8

Write-Host "  Gerando 15 requisicoes durante estresse..." -ForegroundColor Cyan
$scResults = Send-Load -count 15 -delayMs 300
Start-Sleep -Seconds 3
$scMetrics = Get-SystemMetrics
$scPods = Get-PodStatus
$scHPA = Get-HPAStatus
$sc = Count-Results $scResults
$postStressPods = Get-PodCountByApp

$cpuData = Get-Prometheus "rate(container_cpu_usage_seconds_total{namespace='trabalho-sis-dis',container!='POD',container!=''}[1m])"

$report.experiments += @{
    phase = "stress_chaos"; description = "Falha de recurso - sobrecarga CPU 100% com HPA"
    config = @{ cpu_workers=2; cpu_load=100; duration="45s"; mode="all" }
    request_results = $sc
    metrics = $scMetrics
    cpu_usage = $cpuData | ForEach-Object { @{ pod=$_.metric.pod; cpu_cores=[math]::Round([double]$_.value[1], 4) } }
    pods = $scPods; hpa = $scHPA
    pod_counts_before = $preStressPods; pod_counts_after = $postStressPods
}
Write-Host "  OK=$($sc.ok) Degraded=$($sc.degraded) Error=$($sc.error) Latencia=$($sc.avg_ms)ms P95=$($sc.p95_ms)ms" -ForegroundColor $(if ($sc.degraded + $sc.error -gt 0) { "Red" } else { "Green" })
Write-Host "  CB=$($scMetrics.circuit_breaker_state) Failures=$($scMetrics.circuit_breaker_failures)" -ForegroundColor $(if ($scMetrics.circuit_breaker_state -eq "OPEN") { "Red" } else { "Green" })
Write-Host "  Pods antes: Gateway=$($preStressPods.gateway) Servico=$($preStressPods.servico) | Depois: Gateway=$($postStressPods.gateway) Servico=$($postStressPods.servico)" -ForegroundColor Gray
if ($postStressPods.servico -gt $preStressPods.servico) {
    Write-Host "  HPA ESCALOU! Servico: $($preStressPods.servico) -> $($postStressPods.servico) pods" -ForegroundColor Green
} else {
    Write-Host "  HPA: Sem escalonamento detectado (CPU pode nao ter atingido target)" -ForegroundColor Yellow
}

Write-Host "  Removendo StressChaos..." -ForegroundColor Yellow
kubectl delete -f chaos/stress-chaos.yaml 2>$null | Out-Null
Start-Sleep -Seconds 15

# ═══ RECUPERACAO ═══
Write-Host "`n[RECUPERACAO] Verificando pos-experimentos..." -ForegroundColor Yellow
$finalResults = Send-Load -count 10 -delayMs 300
$finalMetrics = Get-SystemMetrics
$finalPods = Get-PodCountByApp
$finalHPA = Get-HPAStatus
$fc = Count-Results $finalResults

$report.experiments += @{
    phase = "recovery"; description = "Verificacao de recuperacao final"
    request_results = $fc; metrics = $finalMetrics; hpa = $finalHPA
    pod_counts = $finalPods
}

# ═══ SUMMARY ═══
$report.summary = @{
    total_experiments = 3
    architecture = @{
        gateway = "Flask (2 replicas, HPA min=2 max=5) - Circuit Breaker + Retry + Timeout"
        servico = "Flask (2 replicas, HPA min=2 max=5) - Redis Cache"
        redis = "Cache (TTL 30s)"
        monitoring = "Prometheus + Grafana + Redis Exporter"
        hpa = "min=2, max=5, target=50% CPU, 70% memory"
    }
    fault_tolerance = @{
        circuit_breaker = "3 falhas -> OPEN, recovery 10s"
        retry = "3 tentativas, backoff linear 0.5s*attempt"
        timeout = "2s per request"
        replicas = "2 por componente (HPA 2-5)"
    }
    results_summary = @{
        network_chaos = "OK=$($nc.ok) Degraded=$($nc.degraded) Error=$($nc.error) CB=$($ncMetrics.circuit_breaker_state)"
        pod_chaos = "OK=$($pc.ok) Degraded=$($pc.degraded) Error=$($pc.error) CB=$($pcMetrics.circuit_breaker_state) mode=one"
        stress_chaos = "OK=$($sc.ok) Degraded=$($sc.degraded) Error=$($sc.error) CB=$($scMetrics.circuit_breaker_state) HPA_scales=$($postStressPods.servico -gt $preStressPods.servico)"
    }
    final_status = if ($fc.degraded + $fc.error -eq 0) { "SISTEMA RECUPERADO" } else { "RECUPERACAO PARCIAL" }
}

# ═══ SALVAR ═══
$outputPath = Join-Path $PSScriptRoot "monitoring-report.json"
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $outputPath -Encoding UTF8

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  RELATORIO: $outputPath" -ForegroundColor White
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "`n=== RESUMO ===" -ForegroundColor Magenta
Write-Host "  Baseline:     $($bc.ok)/$($bc.total) ok | $($bc.degraded) degraded | $($bc.error) error" -ForegroundColor Green
Write-Host "  NetworkChaos: $($nc.ok)/$($nc.total) ok | $($nc.degraded) degraded | $($nc.error) error" -ForegroundColor $(if ($nc.degraded + $nc.error -gt 0) { "Yellow" } else { "Green" })
Write-Host "  PodChaos:     $($pc.ok)/$($pc.total) ok | $($pc.degraded) degraded | $($pc.error) error (mode:one)" -ForegroundColor $(if ($pc.degraded + $pc.error -gt 0) { "Yellow" } else { "Green" })
Write-Host "  StressChaos:  $($sc.ok)/$($sc.total) ok | $($sc.degraded) degraded | $($sc.error) error" -ForegroundColor $(if ($sc.degraded + $sc.error -gt 0) { "Red" } else { "Green" })
Write-Host "  Recuperacao:  $($fc.ok)/$($fc.total) ok | $($fc.degraded) degraded | $($fc.error) error" -ForegroundColor $(if ($fc.degraded + $fc.error -eq 0) { "Green" } else { "Yellow" })
Write-Host "  Status:       $($report.summary.final_status)" -ForegroundColor Green
Write-Host "  HPA Servico:  $($preStressPods.servico) -> $($postStressPods.servico) pods (stress)" -ForegroundColor $(if ($postStressPods.servico -gt $preStressPods.servico) { "Green" } else { "Yellow" })
