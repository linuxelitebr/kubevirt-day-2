<%@ Page Language="C#" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Diagnostics" %>
<%@ Import Namespace="System.Configuration" %>
<%@ Import Namespace="System.Text" %>
<script runat="server">
    // Arquetipo "dynamic-reads-root": le TODOS os fragmentos do content root por request (padrao do
    // cliente: conteudo servido de UNC/DFS). io_ms = esse custo (muda NAS vs local; nenhum cache do IIS
    // cobre I/O de arquivo do app). compute_ms = trabalho local constante. filler = corpo comprimivel.
    //
    // Modo "ma pratica de memoria" (opcional, pra encher RAM e observar NUMA):
    //   LeakKBPerRequest > 0  -> cada request acumula KB numa lista estatica que NUNCA encolhe (leak).
    //   ScanMB > 0            -> cada request LE ScanMB do buffer grande (Application["memHold"], do
    //                            Global.asax), tocando as paginas -> memory-bound e NUMA-sensivel.
    //
    // BLINDADO: nunca estoura; qualquer falha vai no campo "err" com os headers CORS sempre presentes.

    // lista estatica que so cresce = vazamento classico de .NET (nao encolhe, o GC nao pode coletar)
    static readonly System.Collections.Concurrent.ConcurrentBag<byte[]> _leak = new System.Collections.Concurrent.ConcurrentBag<byte[]>();

    void Page_Load(object sender, EventArgs e)
    {
        Response.AppendHeader("Access-Control-Allow-Origin", "*");
        Response.AppendHeader("Timing-Allow-Origin", "*");
        Response.AppendHeader("Cache-Control", "no-store");
        Response.ContentType = "application/json";

        int iters = 2000000, payloadKB = 200, leakKB = 0, scanMB = 0;
        try { int t; if (int.TryParse(ConfigurationManager.AppSettings["ComputeIters"], out t) && t > 0) iters = t; } catch {}
        try { int t; if (int.TryParse(ConfigurationManager.AppSettings["PayloadKB"], out t) && t >= 0) payloadKB = t; } catch {}
        try { int t; if (int.TryParse(ConfigurationManager.AppSettings["LeakKBPerRequest"], out t) && t >= 0) leakKB = t; } catch {}
        try { int t; if (int.TryParse(ConfigurationManager.AppSettings["ScanMB"], out t) && t >= 0) scanMB = t; } catch {}

        // 1) io_ms: le os fragmentos da raiz
        int k = 0; long bytes = 0; double ioMs = 0; string err = "";
        try {
            string dir = Server.MapPath("~/fragments");
            var swIo = Stopwatch.StartNew();
            if (Directory.Exists(dir))
                foreach (var f in Directory.GetFiles(dir, "*.frag")) { bytes += File.ReadAllBytes(f).LongLength; k++; }
            else err = "fragments dir nao encontrado: " + dir;
            swIo.Stop(); ioMs = swIo.Elapsed.TotalMilliseconds;
        } catch (Exception ex) { err = ex.GetType().Name + ": " + ex.Message; }

        // 2) compute_ms: trabalho local constante
        double cpuMs = 0;
        try {
            var swCpu = Stopwatch.StartNew();
            double acc = 0; for (int i = 1; i <= iters; i++) acc += Math.Sqrt(i);
            swCpu.Stop(); cpuMs = swCpu.Elapsed.TotalMilliseconds;
            if (acc < 0) Response.Write("");
        } catch {}

        // 3) leak: acumula KB por request numa lista estatica que nunca encolhe
        long leakMb = 0;
        try {
            if (leakKB > 0) { var b = new byte[leakKB * 1024]; b[0] = 1; b[b.Length - 1] = 1; _leak.Add(b); }
            long ltot = 0; foreach (var x in _leak) ltot += x.LongLength; leakMb = ltot / 1048576;
        } catch {}

        // 4) scan: le ScanMB do buffer grande do Global.asax, tocando as paginas (memory-bound / NUMA)
        double scanMs = 0;
        try {
            var hold = Application["memHold"] as System.Collections.Generic.List<byte[]>;
            if (scanMB > 0 && hold != null && hold.Count > 0) {
                var swS = Stopwatch.StartNew();
                long target = (long)scanMB * 1048576, scanned = 0, acc = 0;
                int idx = new Random().Next(hold.Count);
                while (scanned < target) {
                    var chunk = hold[idx % hold.Count];
                    for (int i = 0; i < chunk.Length; i += 4096) acc += chunk[i];   // toca cada pagina
                    scanned += chunk.Length; idx++;
                }
                swS.Stop(); scanMs = swS.Elapsed.TotalMilliseconds; if (acc < 0) Response.Write("");
            }
        } catch {}

        // 5) runtime/backing/memoria (guardados; trust restrito pode negar Process/WorkingSet)
        string runtime = "n/a", worker = "w3wp", bits = "", backing = "local";
        long heapMb = -1, wsMb = -1;
        try { runtime = ".NET CLR " + Environment.Version; } catch {}
        try { bits = Environment.Is64BitProcess ? "x64" : "x86"; } catch {}
        try { worker = Process.GetCurrentProcess().ProcessName; } catch {}
        try { heapMb = GC.GetTotalMemory(false) / 1048576; } catch {}
        try { wsMb = Process.GetCurrentProcess().WorkingSet64 / 1048576; } catch {}
        try { string ap = System.Web.Hosting.HostingEnvironment.ApplicationPhysicalPath; if (!string.IsNullOrEmpty(ap) && ap.StartsWith("\\\\")) backing = "nas"; } catch {}

        string filler = "";
        try { if (payloadKB > 0) filler = new string('x', payloadKB * 1024); } catch {}

        string errSafe = err.Replace("\\", "\\\\").Replace("\"", "'").Replace("\r", " ").Replace("\n", " ");
        var sb = new StringBuilder();
        sb.Append("{\"fragments\":").Append(k)
          .Append(",\"bytes\":").Append(bytes)
          .Append(",\"io_ms\":").Append(ioMs.ToString("F1"))
          .Append(",\"compute_ms\":").Append(cpuMs.ToString("F1"))
          .Append(",\"scan_ms\":").Append(scanMs.ToString("F1"))
          .Append(",\"leak_mb\":").Append(leakMb)
          .Append(",\"ts\":\"").Append(DateTime.UtcNow.ToString("o")).Append("\"")
          .Append(",\"runtime\":\"").Append(runtime).Append("\"")
          .Append(",\"worker\":\"").Append(worker).Append("\"")
          .Append(",\"bits\":\"").Append(bits).Append("\"")
          .Append(",\"heap_mb\":").Append(heapMb)
          .Append(",\"ws_mb\":").Append(wsMb)
          .Append(",\"backing\":\"").Append(backing).Append("\"")
          .Append(",\"err\":\"").Append(errSafe).Append("\"")
          .Append(",\"filler\":\"").Append(filler).Append("\"}");
        Response.Write(sb.ToString());
    }
</script>
