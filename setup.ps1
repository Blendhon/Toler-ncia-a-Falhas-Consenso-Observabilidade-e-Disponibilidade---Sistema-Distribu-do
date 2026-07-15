# ============================================
# Script de Setup - Trabalho Sistemas Distribuidos
# ============================================

Write-Host "=== Verificando dependencias ===" -ForegroundColor Cyan

$missing = @()

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $missing += "Docker Desktop"
} else {
    Write-Host "[OK] Docker" -ForegroundColor Green
}

if (-not (Get-Command kind -ErrorAction SilentlyContinue)) {
    $missing += "Kind"
} else {
    Write-Host "[OK] Kind" -ForegroundColor Green
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    $missing += "kubectl"
} else {
    Write-Host "[OK] kubectl" -ForegroundColor Green
}

if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    $missing += "Helm"
} else {
    Write-Host "[OK] Helm" -ForegroundColor Green
}

if ($missing.Count -gt 0) {
    Write-Host "`nFerramentas faltando: $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host "Instale antes de continuar:"
    Write-Host "  - Docker Desktop: https://www.docker.com/products/docker-desktop"
    Write-Host "  - Kind: winget install Kubernetes.kind"
    Write-Host "  - kubectl: winget install Kubernetes.kubectl"
    Write-Host "  - Helm: winget install Helm.Helm"
    exit 1
}

Write-Host "`n=== (1/12) Criando cluster Kind ===" -ForegroundColor Cyan
kind delete cluster --name kind 2>$null
kind create cluster --config kind-config.yaml
if (-not $?) { Write-Host "Falha ao criar cluster" -ForegroundColor Red; exit 1 }

Write-Host "`n=== (2/12) Build das imagens Docker ===" -ForegroundColor Cyan
docker build -t gateway:latest -f docker/gateway.Dockerfile .
if (-not $?) { Write-Host "Falha no build da gateway" -ForegroundColor Red; exit 1 }

docker build -t servico:latest -f docker/servico.Dockerfile .
if (-not $?) { Write-Host "Falha no build do servico" -ForegroundColor Red; exit 1 }

Write-Host "`n=== (3/12) Carregando imagens no Kind ===" -ForegroundColor Cyan
kind load docker-image gateway:latest
kind load docker-image servico:latest

Write-Host "`n=== (4/12) Deploy da aplicacao ===" -ForegroundColor Cyan
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/

Write-Host "`nAguardando pods ficarem prontos (60s max)..." -ForegroundColor Yellow
kubectl wait --for=condition=ready pod -l app=gateway -n trabalho-sis-dis --timeout=60s
kubectl wait --for=condition=ready pod -l app=servico -n trabalho-sis-dis --timeout=60s
kubectl wait --for=condition=ready pod -l app=redis -n trabalho-sis-dis --timeout=60s

Write-Host "`n=== (5/12) Instalando Chaos Mesh ===" -ForegroundColor Cyan
helm repo add chaos-mesh https://charts.chaos-mesh.org 2>$null
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --create-namespace --set chaosDaemon.runtime=containerd --set chaosDaemon.socketPath=/run/containerd/containerd.sock

Write-Host "`nAguardando Chaos Mesh (120s max)..." -ForegroundColor Yellow
kubectl wait --for=condition=ready pod -n chaos-mesh --all --timeout=120s

Write-Host "`n=== (6/12) Validando Chaos Mesh ===" -ForegroundColor Cyan

$chaosDaemon = kubectl get pods -n chaos-mesh -l app.kubernetes.io/component=chaos-daemon -o json 2>$null | ConvertFrom-Json
if (-not $chaosDaemon.items -or $chaosDaemon.items.Count -eq 0) {
    Write-Host "[ERRO] Chaos Daemon nao encontrado. Verificando instalacao..." -ForegroundColor Red
    kubectl get pods -n chaos-mesh
} else {
    Write-Host "  Chaos Daemon: $($chaosDaemon.items.Count) pod(s) rodando" -ForegroundColor Green
}

Write-Host "  Verificando socket containerd no no do Kind..." -ForegroundColor Yellow
docker exec kind-control-plane ls -la /run/containerd/containerd.sock 2>$null
if (-not $?) {
    Write-Host "  [AVISO] Socket nao encontrado em /run/containerd/containerd.sock" -ForegroundColor Yellow
    Write-Host "  Tentando caminhos alternativos..." -ForegroundColor Yellow
    docker exec kind-control-plane ls -la /run/dockershim.sock 2>$null
}

Write-Host "`n=== (7/12) Instalando metrics-server (para HPA) ===" -ForegroundColor Cyan
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml 2>$null
if ($?) {
    Write-Host "  metrics-server aplicado. Aguardando pronto (120s max)..." -ForegroundColor Yellow
    kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' 2>$null
    kubectl rollout status deployment metrics-server -n kube-system --timeout=120s 2>$null
    if ($?) {
        Write-Host "  metrics-server pronto!" -ForegroundColor Green
    } else {
        Write-Host "  [AVISO] metrics-server demorou. HPA pode nao funcionar imediatamente." -ForegroundColor Yellow
    }
} else {
    Write-Host "  [AVISO] Falha ao baixar metrics-server. Tentando via kubectl apply..." -ForegroundColor Yellow
}

Write-Host "`n=== (8/12) Aplicando HPA ===" -ForegroundColor Cyan
kubectl apply -f k8s/hpa.yaml
if ($?) {
    Write-Host "  HPA aplicado para Gateway e Servico (min=2, max=5, target=50% CPU)" -ForegroundColor Green
} else {
    Write-Host "  [ERRO] Falha ao aplicar HPA" -ForegroundColor Red
}

Write-Host "`n=== (9/12) Aplicando experimentos de caos ===" -ForegroundColor Cyan
kubectl apply -f chaos/

Write-Host "`n=== (10/12) Deploy do monitoring stack ===" -ForegroundColor Cyan
kubectl apply -f k8s/grafana-secret.yaml
kubectl apply -f k8s/monitoring/

Write-Host "`nAguardando monitoring ficar pronto (60s max)..." -ForegroundColor Yellow
kubectl wait --for=condition=ready pod -l app=prometheus -n trabalho-sis-dis --timeout=60s 2>$null
kubectl wait --for=condition=ready pod -l app=grafana -n trabalho-sis-dis --timeout=60s 2>$null
kubectl wait --for=condition=ready pod -l app=redis-exporter -n trabalho-sis-dis --timeout=60s 2>$null

Write-Host "`n=== (11/12) Verificando HPA ===" -ForegroundColor Cyan
Start-Sleep -Seconds 10
kubectl get hpa -n trabalho-sis-dis 2>$null
$hpaReady = kubectl get hpa -n trabalho-sis-dis -o json 2>$null | ConvertFrom-Json
if ($hpaReady.items -and $hpaReady.items.Count -gt 0) {
    Write-Host "  HPA ativo: $($hpaReady.items.Count) escalador(es)" -ForegroundColor Green
} else {
    Write-Host "  [AVISO] HPA nao encontrado. Verifique metrics-server." -ForegroundColor Yellow
}

Write-Host "`n=== (12/12) Testando a aplicacao ===" -ForegroundColor Cyan
Start-Sleep -Seconds 5

try {
    $response = Invoke-RestMethod -Uri "http://localhost:30000/api/data" -TimeoutSec 10
    Write-Host "`nRESPOSTA:" -ForegroundColor Green
    $response | ConvertTo-Json
    Write-Host "`n[SUCESSO] Aplicacao funcionando!" -ForegroundColor Green
} catch {
    Write-Host "`n[AVISO] Falha no teste inicial. Verifique os pods:" -ForegroundColor Yellow
    kubectl get pods -n trabalho-sis-dis
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  Setup concluido!" -ForegroundColor Green
Write-Host "  HPA: min=2, max=5, target=50% CPU" -ForegroundColor White
Write-Host "  PodChaos: mode=one (1 pod por vez)" -ForegroundColor White
Write-Host "  Teste: curl http://localhost:30000/api/data" -ForegroundColor White
Write-Host "  Logs: kubectl logs -n trabalho-sis-dis -l app=gateway" -ForegroundColor White
Write-Host "  HPA status: kubectl get hpa -n trabalho-sis-dis" -ForegroundColor White
Write-Host "  Demo: .\setup-demo.ps1" -ForegroundColor White
Write-Host "  Experimentos: .\run-experiments.ps1" -ForegroundColor White
Write-Host "============================================" -ForegroundColor Cyan
