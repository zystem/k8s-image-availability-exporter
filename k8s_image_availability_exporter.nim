import std/[base64, envvars, httpclient, net, options, os, re, sets, strutils,
  tables, times, uri]

import promlite
import yyjson
import yaml/[dom, loading]

const
  Version* {.strdefine.} = "0.1.0"
  DefaultRegistry = "index.docker.io"
  DockerHubRegistry = "registry-1.docker.io"
  MetricsPrefix = "k8s_image_availability_exporter_"
  DockerV2ManifestAccept = "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v1+json"
  UsageText* = """k8s-image-availability-exporter

Checks Kubernetes workload images and exports Prometheus metrics.

Usage:
  k8s-image-availability-exporter [--help]

The exporter is configured with environment variables:

  BIND_ADDRESS                         HTTP bind address (default: 0.0.0.0)
  EXPORTER_PORT                        HTTP port (default: 9090)
  REFRESH_INTERVAL_SECONDS             Metrics refresh interval; supports 60, 60s, 5m, 1h (default: 60)
  PROM_LITE_DATA_DIR                   Directory used by promlite for metrics and healthz files (default: /data)
  NAMESPACE_LABEL                      Only check namespaces that have this label (default: all)
  IGNORED_IMAGES                       Tilde-separated image regexes to skip
  ALLOWED_IMAGES                       Tilde-separated image regexes to include
  IMAGE_MIRRORS                        Tilde-separated original=mirror image prefixes
  FORCE_CHECK_DISABLED_CONTROLLERS     Comma-separated kinds or *; deployment,statefulset,daemonset,cronjob
  DEFAULT_REGISTRY                     Registry used for unqualified images (default: index.docker.io)
  ALLOW_PLAIN_HTTP                     Use http:// for registry checks when true
  SKIP_REGISTRY_CERT_VERIFICATION      Skip registry TLS verification when true
  REGISTRY_CA_FILE                     CA bundle for registry HTTPS checks
  KUBECONFIG                           Kubeconfig path for local runs (default: ~/.kube/config)

Kubernetes:
  In cluster, the exporter uses the pod service account token. Outside a
  cluster, it falls back to KUBECONFIG or ~/.kube/config. It reads Deployments,
  StatefulSets, DaemonSets, CronJobs, ServiceAccounts and imagePullSecrets.

Metrics:
  /metrics
  /healthz
"""

type
  AvailabilityMode* = enum
    amAvailable = "available"
    amAbsent = "absent"
    amBadImageFormat = "bad_image_format"
    amRegistryUnavailable = "registry_unavailable"
    amAuthenticationFailure = "authentication_failure"
    amAuthorizationFailure = "authorization_failure"
    amUnknownError = "unknown_error"

  ImageRef* = object
    registry*, repository*, reference*: string
    byDigest*: bool

  RegistryAuth* = object
    username*, password*, identityToken*, registryToken*: string

  ContainerInfo* = object
    namespace*, kind*, name*, container*, image*: string
    pullSecretNames*: seq[string]

  Config* = object
    bindAddress*: string
    port*: int
    dataDir*: string
    refreshIntervalSeconds*: int
    ignoredImages*: seq[Regex]
    allowedImages*: seq[Regex]
    namespaceLabel*: string
    skipRegistryCertVerification*: bool
    allowPlainHttp*: bool
    defaultRegistry*: string
    registryCaPath*: string
    mirrors*: Table[string, string]
    forceKinds*: HashSet[string]

  KubeClient* = object
    baseUrl*: string
    token*: string
    caPath*: string
    certPath*: string
    keyPath*: string
    insecure*: bool

  CheckContext* = object
    config*: Config
    kube*: KubeClient
    authByImage*: Table[string, seq[RegistryAuth]]

proc logInfo(msg: string) =
  echo now().format("yyyy-MM-dd HH:mm:ss','fff") & " - INFO - " & msg

proc logError(msg: string) =
  stderr.writeLine(now().format("yyyy-MM-dd HH:mm:ss','fff") & " - ERROR - " & msg)

proc currentRSSKb(): int =
  try:
    for line in lines("/proc/self/status"):
      if line.startsWith("VmRSS:"):
        return parseInt(line.splitWhitespace()[1])
  except CatchableError:
    discard
  return -1

proc logMem(stage: string) =
  let rss = currentRSSKb()
  if rss >= 0:
    logInfo(stage & " RSS=" & $rss & " KiB")

proc parseDurationSeconds(value: string): int =
  let s = value.strip()
  if s.len == 0:
    return 60
  try:
    if s.endsWith("ms"):
      return max(1, parseInt(s[0 .. ^3]) div 1000)
    if s.endsWith("s"):
      return parseInt(s[0 .. ^2])
    if s.endsWith("m"):
      return parseInt(s[0 .. ^2]) * 60
    if s.endsWith("h"):
      return parseInt(s[0 .. ^2]) * 3600
    return parseInt(s)
  except ValueError:
    raise newException(ValueError, "invalid duration: " & value)

proc parseImageRef*(image: string; defaultRegistry = DefaultRegistry): ImageRef =
  var name = image.strip()
  if name.len == 0 or name.contains("://"):
    raise newException(ValueError, "bad image name: " & image)

  var registry = defaultRegistry
  var remainder = name
  let slash = name.find('/')
  if slash >= 0:
    let first = name[0 ..< slash]
    if first.contains('.') or first.contains(':') or first == "localhost":
      registry = first
      remainder = name[slash + 1 .. ^1]

  if remainder.len == 0 or remainder.startsWith("/") or remainder.contains(" "):
    raise newException(ValueError, "bad image name: " & image)

  var reference = "latest"
  var repository = remainder
  let digestPos = remainder.rfind("@")
  if digestPos >= 0:
    repository = remainder[0 ..< digestPos]
    reference = remainder[digestPos + 1 .. ^1]
    result.byDigest = true
  else:
    let lastSlash = remainder.rfind('/')
    let colon = remainder.rfind(':')
    if colon > lastSlash:
      repository = remainder[0 ..< colon]
      reference = remainder[colon + 1 .. ^1]

  if repository.len == 0 or reference.len == 0:
    raise newException(ValueError, "bad image name: " & image)

  if registry == "docker.io" or registry == "index.docker.io":
    registry = DockerHubRegistry
  if registry in [DefaultRegistry, DockerHubRegistry] and not repository.contains('/'):
    repository = "library/" & repository

  result.registry = registry
  result.repository = repository
  result.reference = reference

proc mirroredImage(image: string; mirrors: Table[string, string]): string =
  for original, mirror in mirrors:
    if image.startsWith(original):
      return mirror & image[original.len .. ^1]
  image

proc bearerToken(auth: RegistryAuth): string =
  if auth.username.len == 0 and auth.password.len == 0:
    return ""
  base64.encode(auth.username & ":" & auth.password)

proc normalizeRegistryKey(key: string): string =
  var value = key.strip()
  if value.startsWith("http://"):
    value = value[7 .. ^1]
  elif value.startsWith("https://"):
    value = value[8 .. ^1]
  if value.endsWith("/v1/"):
    value = value[0 .. ^5]
  if value.endsWith("/"):
    value = value[0 .. ^2]
  if value == "docker.io" or value == "index.docker.io" or value == "https://index.docker.io/v1/":
    return DockerHubRegistry
  value

proc authMatches(authRegistry, imageRegistry: string): bool =
  let a = normalizeRegistryKey(authRegistry)
  let r = normalizeRegistryKey(imageRegistry)
  result = a == r or r.endsWith("." & a)

proc dockerAuthsFromJson*(payload: string; imageRegistry: string): seq[RegistryAuth] =
  var doc = readJson(payload)
  defer: doc.close()
  let root = doc.root()
  let auths = root["auths"]
  if auths.isNil:
    return
  for key, value in auths.pairs:
    let authRegistry = $key
    if not authMatches(authRegistry, imageRegistry):
      continue
    var auth = RegistryAuth(
      username: value.getStr("username"),
      password: value.getStr("password"),
      identityToken: value.getStr("identitytoken"),
      registryToken: value.getStr("registrytoken"))
    let encoded = value.getStr("auth")
    if (auth.username.len == 0 or auth.password.len == 0) and encoded.len > 0:
      try:
        let decoded = base64.decode(encoded)
        let p = decoded.find(':')
        if p >= 0:
          auth.username = decoded[0 ..< p]
          auth.password = decoded[p + 1 .. ^1]
      except ValueError:
        discard
    result.add(auth)

proc newExporterHttpClient(timeoutMs = 15000; token = ""; caPath = ""; certPath = "";
    keyPath = ""; insecure = false): HttpClient =
  var sslContext: SslContext = nil
  when defined(ssl):
    if insecure:
      sslContext = newContext(verifyMode = CVerifyNone, certFile = certPath, keyFile = keyPath)
    elif caPath.len > 0:
      sslContext = newContext(cafile = caPath, certFile = certPath, keyFile = keyPath)
    elif certPath.len > 0 or keyPath.len > 0:
      sslContext = newContext(certFile = certPath, keyFile = keyPath)
  result = httpclient.newHttpClient(timeout = timeoutMs, sslContext = sslContext)
  result.headers = newHttpHeaders({"User-Agent": "k8s-image-availability-exporter/" & Version})
  if token.len > 0:
    result.headers["Authorization"] = "Bearer " & token

proc kubeConfigDefaultPath(): string =
  let explicit = getEnv("KUBECONFIG")
  if explicit.len > 0:
    return explicit.split(PathSep)[0]
  let home = getEnv("HOME")
  if home.len == 0:
    return ""
  home / ".kube" / "config"

proc yamlChild(node: YamlNode; key: string): YamlNode =
  if node.isNil or node.kind != yMapping:
    return nil
  try:
    result = node[key]
  except KeyError:
    result = nil

proc yamlScalar(node: YamlNode): string =
  if node.isNil or node.kind != yScalar:
    return ""
  node.content

proc yamlBool(node: YamlNode): bool =
  yamlScalar(node).normalize() in ["1", "true", "yes", "on"]

proc yamlPath(node: YamlNode; parts: openArray[string]): YamlNode =
  result = node
  for part in parts:
    result = result.yamlChild(part)
    if result.isNil:
      return nil

proc kubeconfigNamedItem(root: YamlNode; section, itemName: string): YamlNode =
  let items = root.yamlChild(section)
  if items.isNil or items.kind != ySequence:
    return nil
  for item in items.items:
    if item.yamlChild("name").yamlScalar() == itemName:
      return item

proc kubeconfigField(root: YamlNode; section, itemName: string;
    fieldPath: openArray[string]): string =
  let item = kubeconfigNamedItem(root, section, itemName)
  if item.isNil:
    return ""
  item.yamlPath(fieldPath).yamlScalar()

proc resolveKubeconfigPath(kubeconfigPath, value: string): string =
  if value.len == 0:
    return ""
  if value.isAbsolute():
    return value
  kubeconfigPath.parentDir() / value

proc safeFileName(value: string): string =
  result = value
  for i, ch in result:
    if not (ch.isAlphaNumeric() or ch in {'-', '_', '.'}):
      result[i] = '-'
  if result.len == 0:
    result = "default"

proc loadKubeClientFromKubeconfig*(path: string): KubeClient =
  if path.len == 0 or not fileExists(path):
    raise newException(ValueError, "KUBERNETES_SERVICE_HOST is not set and kubeconfig was not found: " & path)

  var root: YamlNode
  load(readFile(path), root)
  let currentContext = root.yamlChild("current-context").yamlScalar()
  if currentContext.len == 0:
    raise newException(ValueError, "kubeconfig has no current-context: " & path)

  let clusterName = kubeconfigField(root, "contexts", currentContext, ["context", "cluster"])
  let userName = kubeconfigField(root, "contexts", currentContext, ["context", "user"])
  if clusterName.len == 0:
    raise newException(ValueError, "kubeconfig current context has no cluster: " & currentContext)

  result.baseUrl = kubeconfigField(root, "clusters", clusterName, ["cluster", "server"])
  if result.baseUrl.len == 0:
    raise newException(ValueError, "kubeconfig cluster has no server: " & clusterName)
  result.caPath = resolveKubeconfigPath(path,
    kubeconfigField(root, "clusters", clusterName, ["cluster", "certificate-authority"]))
  let caData = kubeconfigField(root, "clusters", clusterName,
    ["cluster", "certificate-authority-data"])
  if result.caPath.len == 0 and caData.len > 0:
    result.caPath = getTempDir() / "k8s-image-availability-exporter-" & safeFileName(clusterName) & "-ca.crt"
    writeFile(result.caPath, base64.decode(caData))
  result.insecure = kubeconfigNamedItem(root, "clusters", clusterName)
    .yamlPath(["cluster", "insecure-skip-tls-verify"]).yamlBool()

  if userName.len > 0:
    result.token = kubeconfigField(root, "users", userName, ["user", "token"])
    let tokenFile = resolveKubeconfigPath(path,
      kubeconfigField(root, "users", userName, ["user", "tokenFile"]))
    if result.token.len == 0 and tokenFile.len > 0 and fileExists(tokenFile):
      result.token = readFile(tokenFile).strip()
    result.certPath = resolveKubeconfigPath(path,
      kubeconfigField(root, "users", userName, ["user", "client-certificate"]))
    result.keyPath = resolveKubeconfigPath(path,
      kubeconfigField(root, "users", userName, ["user", "client-key"]))
    let certData = kubeconfigField(root, "users", userName, ["user", "client-certificate-data"])
    let keyData = kubeconfigField(root, "users", userName, ["user", "client-key-data"])
    if result.certPath.len == 0 and certData.len > 0:
      result.certPath = getTempDir() / "k8s-image-availability-exporter-" & safeFileName(userName) & "-client.crt"
      writeFile(result.certPath, base64.decode(certData))
    if result.keyPath.len == 0 and keyData.len > 0:
      result.keyPath = getTempDir() / "k8s-image-availability-exporter-" & safeFileName(userName) & "-client.key"
      writeFile(result.keyPath, base64.decode(keyData))

proc inClusterKubeClient(): KubeClient =
  let host = getEnv("KUBERNETES_SERVICE_HOST")
  let port = getEnv("KUBERNETES_SERVICE_PORT", "443")
  if host.len == 0:
    return loadKubeClientFromKubeconfig(kubeConfigDefaultPath())
  let tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
  result.baseUrl = "https://" & host & ":" & port
  result.token = readFile(tokenPath).strip()
  let ca = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
  if fileExists(ca):
    result.caPath = ca

proc apiGet(kube: KubeClient; path: string): string =
  var client = newExporterHttpClient(token = kube.token, caPath = kube.caPath,
    certPath = kube.certPath, keyPath = kube.keyPath, insecure = kube.insecure)
  defer: client.close()
  let response = client.request(kube.baseUrl & path, httpMethod = HttpGet)
  if response.status[0] != '2':
    raise newException(IOError, "Kubernetes API " & path & " returned " & response.status)
  response.body

proc listPathWithContinue*(path, continueToken: string; limit = 500): string =
  var resultPath = path
  let sep = if resultPath.contains("?"): "&" else: "?"
  resultPath.add(sep & "limit=" & $limit)
  if continueToken.len > 0:
    resultPath.add("&continue=" & encodeUrl(continueToken))
  resultPath

proc apiListBodies(kube: KubeClient; path: string): seq[string] =
  var continueToken = ""
  while true:
    let body = kube.apiGet(listPathWithContinue(path, continueToken))
    result.add(body)
    var doc = readJson(body)
    defer: doc.close()
    continueToken = doc.root()["metadata"].getStr("continue")
    if continueToken.len == 0:
      break

proc optStr(v: JsonVal; key: string; default = ""): string =
  result = if v.isNil: default else: v.getStr(key, default)

proc optBool(v: JsonVal; key: string; default = false): bool =
  result = if v.isNil: default else: v.getBool(key, default)

proc optInt(v: JsonVal; key: string; default = 0): int =
  result = if v.isNil: default else: v.getInt(key, default)

proc namespaceAllowed(ns: JsonVal; label: string): bool =
  if label.len == 0:
    return true
  let labels = ns["metadata"]["labels"]
  result = not labels.isNil and labels.hasKey(label)

proc listAllowedNamespaces(ctx: CheckContext): HashSet[string] =
  for body in ctx.kube.apiListBodies("/api/v1/namespaces"):
    var doc = readJson(body)
    defer: doc.close()
    for ns in doc.root()["items"].items:
      if namespaceAllowed(ns, ctx.config.namespaceLabel):
        result.incl(ns["metadata"].getStr("name"))

proc secretNamesFromRefs(secretRefs: JsonVal): seq[string] =
  if secretRefs.isNil:
    return
  for secretRef in secretRefs.items:
    let name = secretRef.getStr("name")
    if name.len > 0:
      result.add(name)

proc serviceAccountSecretNames(ctx: CheckContext; namespace, serviceAccount: string): seq[string] =
  let name = if serviceAccount.len > 0: serviceAccount else: "default"
  try:
    let body = ctx.kube.apiGet("/api/v1/namespaces/" & encodeUrl(namespace) & "/serviceaccounts/" & encodeUrl(name))
    var doc = readJson(body)
    defer: doc.close()
    return doc.root()["imagePullSecrets"].secretNamesFromRefs()
  except CatchableError as e:
    logError("Cannot read serviceaccount " & namespace & "/" & name & ": " & e.msg)

proc extractContainers(namespace, kind, name: string; spec: JsonVal; pullSecrets: seq[string]): seq[ContainerInfo] =
  for field in ["containers", "initContainers", "ephemeralContainers"]:
    for c in spec[field].items:
      let image = c.getStr("image")
      let container = c.getStr("name")
      if image.len > 0 and container.len > 0:
        result.add(ContainerInfo(namespace: namespace, kind: kind, name: name,
          container: container, image: image, pullSecretNames: pullSecrets))

proc workloadEnabled(kind: string; item: JsonVal): bool =
  case kind
  of "Deployment", "StatefulSet":
    item["spec"].optInt("replicas", 1) > 0
  of "DaemonSet":
    item["status"].optInt("currentNumberScheduled", 0) > 0
  of "CronJob":
    not item["spec"].optBool("suspend", false)
  else:
    true

proc includeImage(image: string; allowed, ignored: seq[Regex]): bool =
  if allowed.len > 0:
    var ok = false
    for r in allowed:
      if image.match(r):
        ok = true
        break
    if not ok:
      return false
  for r in ignored:
    if image.match(r):
      return false
  true

proc collectWorkload(ctx: CheckContext; path, kind: string; namespaces: HashSet[string]): seq[ContainerInfo] =
  for body in ctx.kube.apiListBodies(path):
    var doc = readJson(body)
    defer: doc.close()
    for item in doc.root()["items"].items:
      let meta = item["metadata"]
      let namespace = meta.getStr("namespace")
      if namespace notin namespaces:
        continue
      if not workloadEnabled(kind, item) and kind.toLowerAscii() notin ctx.config.forceKinds and "*" notin ctx.config.forceKinds:
        continue
      let name = meta.getStr("name")
      let podSpec =
        if kind == "CronJob": item["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        else: item["spec"]["template"]["spec"]
      var pullSecrets = podSpec["imagePullSecrets"].secretNamesFromRefs()
      if pullSecrets.len == 0:
        pullSecrets = ctx.serviceAccountSecretNames(namespace, podSpec.optStr("serviceAccountName"))
      for ci in extractContainers(namespace, kind, name, podSpec, pullSecrets):
        if includeImage(ci.image, ctx.config.allowedImages, ctx.config.ignoredImages):
          result.add(ci)

proc secretAuths(ctx: CheckContext; namespace, secretName, imageRegistry: string): seq[RegistryAuth] =
  try:
    let body = ctx.kube.apiGet("/api/v1/namespaces/" & encodeUrl(namespace) & "/secrets/" & encodeUrl(secretName))
    var doc = readJson(body)
    defer: doc.close()
    let root = doc.root()
    let typ = root.getStr("type")
    let data = root["data"]
    if data.isNil:
      return
    var encoded = ""
    if typ == "kubernetes.io/dockerconfigjson":
      encoded = data.getStr(".dockerconfigjson")
    elif typ == "kubernetes.io/dockercfg":
      encoded = data.getStr(".dockercfg")
    if encoded.len == 0:
      return
    let payload = base64.decode(encoded)
    if typ == "kubernetes.io/dockercfg":
      return dockerAuthsFromJson("""{"auths":""" & payload & "}", imageRegistry)
    else:
      return dockerAuthsFromJson(payload, imageRegistry)
  except CatchableError as e:
    logError("Cannot read imagePullSecret " & namespace & "/" & secretName & ": " & e.msg)

proc uniqueAuths(auths: seq[RegistryAuth]): seq[RegistryAuth] =
  var seen = initHashSet[string]()
  for auth in auths:
    let key = auth.username & "\0" & auth.password & "\0" & auth.identityToken & "\0" & auth.registryToken
    if key notin seen:
      seen.incl(key)
      result.add(auth)

proc buildAuthIndex(ctx: var CheckContext; containers: seq[ContainerInfo]) =
  for ci in containers:
    let image = mirroredImage(ci.image, ctx.config.mirrors)
    let imageRef = parseImageRef(image, ctx.config.defaultRegistry)
    var auths: seq[RegistryAuth] = @[]
    for secretName in ci.pullSecretNames:
      auths.add(ctx.secretAuths(ci.namespace, secretName, imageRef.registry))
    ctx.authByImage.mgetOrPut(ci.image, @[]).add(auths)
  for image, auths in ctx.authByImage.mpairs:
    auths = uniqueAuths(auths)

proc parseAuthChallenge*(header: string): Table[string, string] =
  var h = header.strip()
  if h.toLowerAscii().startsWith("bearer "):
    h = h[7 .. ^1]
  var i = 0
  while i < h.len:
    while i < h.len and h[i] in {' ', ','}: inc i
    let start = i
    while i < h.len and h[i] notin {'=', ','}: inc i
    if i >= h.len or h[i] != '=':
      break
    let key = h[start ..< i].strip().toLowerAscii()
    inc i
    var value = ""
    if i < h.len and h[i] == '"':
      inc i
      while i < h.len:
        if h[i] == '"':
          inc i
          break
        if h[i] == '\\' and i + 1 < h.len:
          inc i
        value.add(h[i])
        inc i
    else:
      let vStart = i
      while i < h.len and h[i] != ',': inc i
      value = h[vStart ..< i].strip()
    if key.len > 0:
      result[key] = value

proc applyRegistryAuth(client: HttpClient; auth: RegistryAuth) =
  if auth.registryToken.len > 0:
    client.headers["Authorization"] = "Bearer " & auth.registryToken
  elif auth.identityToken.len > 0:
    client.headers["Authorization"] = "Bearer " & auth.identityToken
  else:
    let token = bearerToken(auth)
    if token.len > 0:
      client.headers["Authorization"] = "Basic " & token

proc requestBearerToken(realm, service, scope: string; auth: RegistryAuth; caPath: string; insecure: bool): Option[string] =
  if realm.len == 0:
    return none(string)
  var url = realm
  var sep = if url.contains("?"): "&" else: "?"
  if service.len > 0:
    url.add(sep & "service=" & encodeUrl(service))
    sep = "&"
  if scope.len > 0:
    url.add(sep & "scope=" & encodeUrl(scope))
  var client = newExporterHttpClient(caPath = caPath, insecure = insecure)
  defer: client.close()
  client.applyRegistryAuth(auth)
  let response = client.request(url, httpMethod = HttpGet)
  if response.status[0] != '2':
    return none(string)
  var doc = readJson(response.body)
  defer: doc.close()
  let token = doc.root().getStr("token", doc.root().getStr("access_token"))
  result = if token.len == 0: none(string) else: some(token)

proc manifestUrl(imageRef: ImageRef; plainHttp: bool): string =
  let scheme = if plainHttp: "http://" else: "https://"
  result = scheme & imageRef.registry & "/v2/" & imageRef.repository & "/manifests/" & encodeUrl(imageRef.reference)

proc classifyManifestResponse(response: Response): AvailabilityMode =
  case response.code
  of Http200, Http201, Http202:
    amAvailable
  of Http404:
    amAbsent
  of Http403:
    amAuthorizationFailure
  of Http401:
    amAuthenticationFailure
  else:
    amUnknownError

proc newRegistryHttpClient(config: Config): HttpClient =
  result = newExporterHttpClient(
    caPath = config.registryCaPath,
    insecure = config.skipRegistryCertVerification)
  result.headers["Accept"] = DockerV2ManifestAccept

proc requestManifest(config: Config; url: string; auth: RegistryAuth;
    bearerToken = ""): Response =
  var client = newRegistryHttpClient(config)
  defer: client.close()
  if bearerToken.len > 0:
    client.headers["Authorization"] = "Bearer " & bearerToken
  else:
    client.applyRegistryAuth(auth)
  result = client.request(url, httpMethod = HttpHead)
  if result.code == Http405:
    var getClient = newRegistryHttpClient(config)
    defer: getClient.close()
    if bearerToken.len > 0:
      getClient.headers["Authorization"] = "Bearer " & bearerToken
    else:
      getClient.applyRegistryAuth(auth)
    result = getClient.request(url, httpMethod = HttpGet)

proc checkWithAuth*(image: string; auth: RegistryAuth; config: Config): AvailabilityMode =
  let mirrored = mirroredImage(image, config.mirrors)
  let imageRef = parseImageRef(mirrored, config.defaultRegistry)
  let url = manifestUrl(imageRef, config.allowPlainHttp)
  let response = requestManifest(config, url, auth)
  case response.code
  of Http200, Http201, Http202:
    return amAvailable
  of Http404:
    return amAbsent
  of Http403:
    return amAuthorizationFailure
  of Http401:
    let challenge = response.headers.getOrDefault("www-authenticate")
    if challenge.toLowerAscii().startsWith("bearer "):
      let parts = parseAuthChallenge(challenge)
      let scope = parts.getOrDefault("scope", "repository:" & imageRef.repository & ":pull")
      let token = requestBearerToken(parts.getOrDefault("realm"), parts.getOrDefault("service"), scope,
        auth, config.registryCaPath, config.skipRegistryCertVerification)
      if token.isSome:
        return classifyManifestResponse(requestManifest(config, url, auth, token.get()))
    return amAuthenticationFailure
  else:
    return amUnknownError

proc isRegistryUnavailableError(e: ref CatchableError): bool =
  let msg = e.msg.toLowerAscii()
  result =
    e of TimeoutError or
    e of OSError or
    e of SslError or
    msg.contains("connection refused") or
    msg.contains("could not connect") or
    msg.contains("failed to connect") or
    msg.contains("name or service not known") or
    msg.contains("temporary failure in name resolution") or
    msg.contains("network is unreachable") or
    msg.contains("no route to host") or
    msg.contains("certificate") or
    msg.contains("tls") or
    msg.contains("ssl")

proc checkImage(ctx: CheckContext; image: string): AvailabilityMode =
  try:
    let auths = ctx.authByImage.getOrDefault(image, @[])
    if auths.len == 0:
      return checkWithAuth(image, RegistryAuth(), ctx.config)
    var sawAuthn = false
    var sawAuthz = false
    for auth in auths:
      let mode = checkWithAuth(image, auth, ctx.config)
      if mode == amAvailable or mode == amAbsent:
        return mode
      if mode == amAuthenticationFailure: sawAuthn = true
      elif mode == amAuthorizationFailure: sawAuthz = true
    if sawAuthz: amAuthorizationFailure
    elif sawAuthn: amAuthenticationFailure
    else: amUnknownError
  except ValueError:
    amBadImageFormat
  except CatchableError as e:
    logError("Cannot check image " & image & ": " & e.msg)
    if isRegistryUnavailableError(e): amRegistryUnavailable else: amUnknownError

proc collectContainers(ctx: CheckContext): seq[ContainerInfo] =
  let namespaces = ctx.listAllowedNamespaces()
  result.add(ctx.collectWorkload("/apis/apps/v1/deployments", "Deployment", namespaces))
  result.add(ctx.collectWorkload("/apis/apps/v1/statefulsets", "StatefulSet", namespaces))
  result.add(ctx.collectWorkload("/apis/apps/v1/daemonsets", "DaemonSet", namespaces))
  result.add(ctx.collectWorkload("/apis/batch/v1/cronjobs", "CronJob", namespaces))

proc emitAvailability(m: var MetricsBuilder; ci: ContainerInfo; mode: AvailabilityMode) =
  let labels = {
    "namespace": ci.namespace,
    "container": ci.container,
    "image": ci.image,
    "kind": ci.kind.toLowerAscii(),
    "name": ci.name
  }
  for candidate in AvailabilityMode:
    let metricName = MetricsPrefix & $candidate
    m.gauge(metricName, if candidate == mode: 1 else: 0, labels)

proc collectMetrics*(ctx: var CheckContext; m: var MetricsBuilder) =
  let refreshStarted = epochTime()
  logInfo("Refreshing metrics file")
  logMem("refresh start")

  m.help(MetricsPrefix & "available", "Image is available from its registry")
  m.help(MetricsPrefix & "absent", "Image manifest is absent in its registry")
  m.help(MetricsPrefix & "bad_image_format", "Image name cannot be parsed")
  m.help(MetricsPrefix & "registry_unavailable", "Registry did not respond successfully")
  m.help(MetricsPrefix & "authentication_failure", "Registry authentication failed")
  m.help(MetricsPrefix & "authorization_failure", "Registry authorization failed")
  m.help(MetricsPrefix & "unknown_error", "Image check failed for an unclassified reason")
  m.help(MetricsPrefix & "completed_rechecks_total", "Number of image rechecks completed")
  m.counter(MetricsPrefix & "completed_rechecks_total", 1)
  m.help(MetricsPrefix & "build_info", "Exporter build information")
  m.info(MetricsPrefix & "build_info", labels = {"version": Version})
  m.help(MetricsPrefix & "refresh_duration_seconds", "Duration of the last metrics refresh")
  m.help(MetricsPrefix & "containers_total", "Containers processed during the last metrics refresh")
  m.help(MetricsPrefix & "images_total", "Unique images checked during the last metrics refresh")
  m.help(MetricsPrefix & "registry_checks_total", "Registry checks completed during the last metrics refresh")
  m.help(MetricsPrefix & "kubernetes_api_errors_total", "Kubernetes API errors seen during the last metrics refresh")

  var kubernetesApiErrors = 0
  let containers = try:
      ctx.collectContainers()
    except CatchableError as e:
      inc kubernetesApiErrors
      logError("Cannot collect Kubernetes workloads: " & e.msg)
      newSeq[ContainerInfo]()
  logInfo("Containers count=" & $containers.len)
  ctx.authByImage.clear()
  ctx.buildAuthIndex(containers)
  var cache = initTable[string, AvailabilityMode]()
  for ci in containers:
    let mode = cache.mgetOrPut(ci.image, ctx.checkImage(ci.image))
    m.emitAvailability(ci, mode)
  for mode in AvailabilityMode:
    var count = 0
    for _, cachedMode in cache:
      if cachedMode == mode:
        inc count
    m.counter(MetricsPrefix & "registry_checks_total", count, labels = {"mode": $mode})
  m.counter(MetricsPrefix & "kubernetes_api_errors_total", kubernetesApiErrors)
  m.gauge(MetricsPrefix & "refresh_duration_seconds", epochTime() - refreshStarted)
  m.gauge(MetricsPrefix & "containers_total", containers.len)
  m.gauge(MetricsPrefix & "images_total", cache.len)

  logInfo("Metrics file refreshed successfully")
  logMem("refresh done")

proc splitEnvList(value: string; sep = '~'): seq[string] =
  for item in value.split(sep):
    let stripped = item.strip()
    if stripped.len > 0:
      result.add(stripped)

proc parseRegexEnv(value: string): seq[Regex] =
  for item in splitEnvList(value):
    result.add(re(item))

proc parseMirrorEnv(value: string): Table[string, string] =
  result = initTable[string, string]()
  for item in splitEnvList(value):
    let p = item.find('=')
    if p < 1:
      raise newException(ValueError, "invalid image mirror, expected original=mirror: " & item)
    result[item[0 ..< p]] = item[p + 1 .. ^1]

proc parseBoolEnv(name: string; default = false): bool =
  let value = getEnv(name)
  if value.len == 0:
    return default
  value.normalize() in ["1", "true", "yes", "on"]

proc defaultConfig*(): Config =
  result.bindAddress = "0.0.0.0"
  result.port = 9090
  result.dataDir = "/data"
  result.refreshIntervalSeconds = 60
  result.defaultRegistry = DefaultRegistry
  result.mirrors = initTable[string, string]()
  result.forceKinds = initHashSet[string]()

proc parseForceKinds(value: string): HashSet[string] =
  for part in value.split(','):
    let item = part.strip()
    if item.len == 0:
      continue
    if item == "*":
      result.incl("*")
    else:
      result.incl(item.toLowerAscii())

proc loadConfig*(): Config =
  result = defaultConfig()
  result.bindAddress = getEnv("BIND_ADDRESS", result.bindAddress)
  result.port = parseInt(getEnv("EXPORTER_PORT", $result.port))
  result.dataDir = getEnv("PROM_LITE_DATA_DIR", result.dataDir)
  result.refreshIntervalSeconds = parseDurationSeconds(
    getEnv("REFRESH_INTERVAL_SECONDS", $result.refreshIntervalSeconds))
  result.namespaceLabel = getEnv("NAMESPACE_LABEL", "")
  result.skipRegistryCertVerification = parseBoolEnv("SKIP_REGISTRY_CERT_VERIFICATION")
  result.allowPlainHttp = parseBoolEnv("ALLOW_PLAIN_HTTP")
  result.defaultRegistry = getEnv("DEFAULT_REGISTRY", result.defaultRegistry)
  result.registryCaPath = getEnv("REGISTRY_CA_FILE", "")
  result.ignoredImages = parseRegexEnv(getEnv("IGNORED_IMAGES", ""))
  result.allowedImages = parseRegexEnv(getEnv("ALLOWED_IMAGES", ""))
  result.mirrors = parseMirrorEnv(getEnv("IMAGE_MIRRORS", ""))
  result.forceKinds = parseForceKinds(getEnv("FORCE_CHECK_DISABLED_CONTROLLERS", ""))

proc main() =
  let args = commandLineParams()
  if args.len > 0:
    if args.len == 1 and args[0] in ["-h", "--help", "help"]:
      stdout.write(UsageText)
      quit(0)
    stderr.writeLine("Unknown arguments: " & args.join(" "))
    stderr.writeLine("Run with --help to see usage.")
    quit(2)

  var config = loadConfig()
  let kube = inClusterKubeClient()
  var ctx = CheckContext(config: config, kube: kube, authByImage: initTable[string, seq[RegistryAuth]]())
  proc collector(m: var MetricsBuilder) {.gcsafe.} =
    {.cast(gcsafe).}:
      ctx.collectMetrics(m)

  logInfo("Starting HTTP server on " & config.bindAddress & ":" & $config.port)
  let exporter = newExporter(
    address = config.bindAddress,
    port = config.port,
    refreshIntervalSeconds = config.refreshIntervalSeconds,
    dataDir = config.dataDir,
    metricsFileName = "metrics",
    collector = collector)
  exporter.run()

when isMainModule:
  main()
