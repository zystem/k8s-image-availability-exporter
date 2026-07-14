import std/[base64, net, os, strutils, tables, unittest]

import promlite

import ../src/k8s_image_availability_exporter

const FakeRegistryPort = 18081
const FakeFullFlowPort = 18082
const FakeHeadFallbackPort = 18083

proc readHttpRequest(socket: Socket): string =
  try:
    while true:
      let line = socket.recvLine(timeout = 3000)
      if line.strip().len == 0:
        break
      result.add(line & "\n")
  except TimeoutError:
    discard

proc sendHttp(socket: Socket; status, headers, body: string) =
  socket.send("HTTP/1.1 " & status & "\r\n")
  socket.send("Connection: close\r\n")
  socket.send("Content-Length: " & $body.len & "\r\n")
  socket.send(headers)
  socket.send("\r\n")
  socket.send(body)

proc fakeRegistryServer() {.thread.} =
  var server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(FakeRegistryPort), "127.0.0.1")
  server.listen()
  defer: server.close()

  var handled = 0
  var attempts = 0
  while handled < 3 and attempts < 8:
    inc attempts
    var client: Socket
    server.accept(client)
    let req = client.readHttpRequest()
    let reqLower = req.toLowerAscii()
    if req.len == 0:
      client.close()
      continue
    inc handled
    if req.startsWith("HEAD /v2/team/app/manifests/1") and "authorization: bearer harbor-token" in reqLower:
      client.sendHttp("200 OK", "", "")
    elif req.startsWith("HEAD /v2/team/app/manifests/1"):
      client.sendHttp("401 Unauthorized",
        "WWW-Authenticate: Bearer realm=\"http://127.0.0.1:" & $FakeRegistryPort &
        "/token\",service=\"harbor\",scope=\"repository:team/app:pull\"\r\n", "")
    elif req.startsWith("GET /token") and ("authorization: basic " & base64.encode("robot:s3cr3t").toLowerAscii()) in reqLower:
      client.sendHttp("200 OK", "Content-Type: application/json\r\n", """{"token":"harbor-token"}""")
    else:
      client.sendHttp("500 Internal Server Error", "", "")
    client.close()

proc dockerConfigJson(registry: string): string =
  let auth = base64.encode("robot:s3cr3t")
  """{"auths":{"""" & registry & """":{"auth":"""" & auth & """"}}}"""

proc fakeFullFlowServer() {.thread.} =
  var server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(FakeFullFlowPort), "127.0.0.1")
  server.listen()
  defer: server.close()

  let registry = "127.0.0.1:" & $FakeFullFlowPort
  let secretData = base64.encode(dockerConfigJson(registry))

  while true:
    var client: Socket
    server.accept(client)
    let req = client.readHttpRequest()
    let reqLower = req.toLowerAscii()
    if req.len == 0:
      client.close()
      continue

    if req.startsWith("GET /api/v1/namespaces?"):
      client.sendHttp("200 OK", "Content-Type: application/json\r\n",
        """{"metadata":{},"items":[{"metadata":{"name":"default"}}]}""")
    elif req.startsWith("GET /apis/apps/v1/deployments?"):
      client.sendHttp("200 OK", "Content-Type: application/json\r\n",
        """{"metadata":{},"items":[{"metadata":{"namespace":"default","name":"app"},"spec":{"replicas":1,"template":{"spec":{"serviceAccountName":"app-sa","initContainers":[{"name":"init-db","image":"127.0.0.1:""" &
        $FakeFullFlowPort & """/team/app:1"}],"containers":[]}}}}]}""")
    elif req.startsWith("GET /apis/apps/v1/statefulsets?") or
        req.startsWith("GET /apis/apps/v1/daemonsets?") or
        req.startsWith("GET /apis/batch/v1/cronjobs?"):
      client.sendHttp("200 OK", "Content-Type: application/json\r\n", """{"metadata":{},"items":[]}""")
    elif req.startsWith("GET /api/v1/namespaces/default/serviceaccounts/app-sa"):
      client.sendHttp("200 OK", "Content-Type: application/json\r\n",
        """{"imagePullSecrets":[{"name":"registry-auth"}]}""")
    elif req.startsWith("GET /api/v1/namespaces/default/secrets/registry-auth"):
      client.sendHttp("200 OK", "Content-Type: application/json\r\n",
        """{"type":"kubernetes.io/dockerconfigjson","data":{".dockerconfigjson":"""" & secretData & """"}}""")
    elif req.startsWith("HEAD /v2/team/app/manifests/1") and "authorization: bearer harbor-token" in reqLower:
      client.sendHttp("200 OK", "", "")
      client.close()
      break
    elif req.startsWith("HEAD /v2/team/app/manifests/1"):
      client.sendHttp("401 Unauthorized",
        "WWW-Authenticate: Bearer realm=\"http://127.0.0.1:" & $FakeFullFlowPort &
        "/token\",service=\"harbor\",scope=\"repository:team/app:pull\"\r\n", "")
    elif req.startsWith("GET /token") and ("authorization: basic " & base64.encode("robot:s3cr3t").toLowerAscii()) in reqLower:
      client.sendHttp("200 OK", "Content-Type: application/json\r\n", """{"token":"harbor-token"}""")
    elif req.startsWith("HEAD /v2/library/busybox/manifests/1"):
      client.sendHttp("200 OK", "", "")
    else:
      client.sendHttp("500 Internal Server Error", "", "")
    client.close()

proc fakeHeadFallbackServer() {.thread.} =
  var server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(FakeHeadFallbackPort), "127.0.0.1")
  server.listen()
  defer: server.close()

  var handled = 0
  while handled < 2:
    var client: Socket
    server.accept(client)
    let req = client.readHttpRequest()
    if req.startsWith("HEAD /v2/team/app/manifests/1"):
      client.sendHttp("405 Method Not Allowed", "", "")
      inc handled
    elif req.startsWith("GET /v2/team/app/manifests/1"):
      client.sendHttp("200 OK", "Content-Type: application/json\r\n", "{}")
      inc handled
    else:
      client.sendHttp("500 Internal Server Error", "", "")
    client.close()

suite "image references":
  test "docker hub defaults":
    let imageRef = parseImageRef("redis:7")
    check imageRef.registry == "registry-1.docker.io"
    check imageRef.repository == "library/redis"
    check imageRef.reference == "7"

  test "qualified registry":
    let imageRef = parseImageRef("harbor.example.com/team/app@sha256:abcdef")
    check imageRef.registry == "harbor.example.com"
    check imageRef.repository == "team/app"
    check imageRef.reference == "sha256:abcdef"
    check imageRef.byDigest

suite "docker auth secrets":
  test "dockerconfigjson auth":
    let encoded = base64.encode("robot$ci:s3cr3t")
    let payload = """{"auths":{"harbor.example.com":{"auth":"""" & encoded & """"}}}"""
    let auths = dockerAuthsFromJson(payload, "harbor.example.com")
    check auths.len == 1
    check auths[0].username == "robot$ci"
    check auths[0].password == "s3cr3t"

  test "docker.io aliases":
    let payload = """{"auths":{"https://index.docker.io/v1/":{"username":"u","password":"p"}}}"""
    let auths = dockerAuthsFromJson(payload, "registry-1.docker.io")
    check auths.len == 1
    check auths[0].username == "u"

suite "registry bearer challenge":
  test "quoted challenge":
    let parsed = parseAuthChallenge("""Bearer realm="https://harbor.example.com/service/token",service="harbor-registry",scope="repository:team/app:pull"""")
    check parsed["realm"] == "https://harbor.example.com/service/token"
    check parsed["service"] == "harbor-registry"
    check parsed["scope"] == "repository:team/app:pull"

  test "checks private registry with docker auth and bearer token":
    var thread: Thread[void]
    createThread(thread, fakeRegistryServer)
    sleep(100)

    var config = defaultConfig()
    config.allowPlainHttp = true
    let auth = RegistryAuth(username: "robot", password: "s3cr3t")
    check checkWithAuth("127.0.0.1:" & $FakeRegistryPort & "/team/app:1", auth, config) == amAvailable

    joinThread(thread)

  test "collects Kubernetes imagePullSecrets through private registry flow":
    var thread: Thread[void]
    createThread(thread, fakeFullFlowServer)
    sleep(100)

    var config = defaultConfig()
    config.allowPlainHttp = true
    config.defaultRegistry = "127.0.0.1:" & $FakeFullFlowPort
    var ctx = CheckContext(
      config: config,
      kube: KubeClient(baseUrl: "http://127.0.0.1:" & $FakeFullFlowPort),
      authByImage: initTable[string, seq[RegistryAuth]]())
    var builder = initMetricsBuilder()
    ctx.collectMetrics(builder)
    let text = $builder

    check "container=\"init-db\"" in text
    check "image=\"127.0.0.1:" & $FakeFullFlowPort & "/team/app:1\"" in text
    check "k8s_image_availability_exporter_available" in text
    check "k8s_image_availability_exporter_registry_checks_total{mode=\"available\"} 1" in text

    joinThread(thread)

  test "falls back from HEAD to GET manifest":
    var thread: Thread[void]
    createThread(thread, fakeHeadFallbackServer)
    sleep(100)

    var config = defaultConfig()
    config.allowPlainHttp = true
    check checkWithAuth("127.0.0.1:" & $FakeHeadFallbackPort & "/team/app:1",
      RegistryAuth(), config) == amAvailable

    joinThread(thread)

suite "usage":
  test "documents env configuration":
    check "Usage:" in UsageText
    check "EXPORTER_PORT" in UsageText
    check "PROM_LITE_DATA_DIR" in UsageText
    check "KUBECONFIG" in UsageText
    check "imagePullSecrets" in UsageText

suite "kubernetes api":
  test "builds paginated list paths":
    check listPathWithContinue("/api/v1/namespaces", "") == "/api/v1/namespaces?limit=500"
    check listPathWithContinue("/apis/apps/v1/deployments?labelSelector=a", "next/page") ==
      "/apis/apps/v1/deployments?labelSelector=a&limit=500&continue=next%2Fpage"

  test "loads token kubeconfig":
    let path = getTempDir() / "k8s-image-availability-exporter-test-kubeconfig.yaml"
    let tokenPath = getTempDir() / "k8s-image-availability-exporter-test-token"
    writeFile(tokenPath, "test-token\n")
    writeFile(path, """
apiVersion: v1
kind: Config
current-context: "dev"
clusters: [{name: local, cluster: {server: "https://127.0.0.1:6443", insecure-skip-tls-verify: true}}]
contexts:
- name: dev
  context:
    cluster: local
    user: robot
users:
- name: robot
  user:
    tokenFile: """ & tokenPath.extractFilename() & """
""")
    defer:
      if fileExists(path):
        removeFile(path)
      if fileExists(tokenPath):
        removeFile(tokenPath)

    let kube = loadKubeClientFromKubeconfig(path)
    check kube.baseUrl == "https://127.0.0.1:6443"
    check kube.token == "test-token"
    check kube.insecure

  test "loads kubeconfig client certificate data":
    let path = getTempDir() / "k8s-image-availability-exporter-test-kubeconfig-cert.yaml"
    let caData = base64.encode("ca")
    let certData = base64.encode("cert")
    let keyData = base64.encode("key")
    writeFile(path, [
      "apiVersion: v1",
      "kind: Config",
      "current-context: dev",
      "clusters:",
      "- name: local",
      "  cluster:",
      "    server: https://127.0.0.1:6443",
      "    certificate-authority-data: " & caData,
      "contexts:",
      "- name: dev",
      "  context:",
      "    cluster: local",
      "    user: robot",
      "users:",
      "- name: robot",
      "  user:",
      "    client-certificate-data: " & certData,
      "    client-key-data: " & keyData,
      ""
    ].join("\n"))
    defer:
      if fileExists(path):
        removeFile(path)

    let kube = loadKubeClientFromKubeconfig(path)
    check kube.caPath.len > 0
    check kube.certPath.len > 0
    check kube.keyPath.len > 0
    check fileExists(kube.caPath)
    check fileExists(kube.certPath)
    check fileExists(kube.keyPath)
