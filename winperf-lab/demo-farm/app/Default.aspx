<%@ Page Language="C#" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Diagnostics" %>
<%@ Import Namespace="System.Configuration" %>
<%@ Import Namespace="System.Text" %>
<script runat="server">
    // Arquetipo "dynamic-reads-root": le TODOS os fragmentos do content root por request (o padrao do
    // cliente: conteudo servido de UNC/DFS). io_ms = esse custo (muda NAS vs local; nenhum cache do IIS
    // cobre I/O de arquivo do app). compute_ms = trabalho local constante. filler = corpo comprimivel.
    //
    // BLINDADO: nunca estoura. Qualquer falha (ex.: leitura do NAS negada porque a identidade do pool
    // nao alcanca o share, ou chamada de trust restrito) e' capturada e vai no campo "err" do JSON, com
    // os headers de CORS SEMPRE presentes - assim o erro aparece no dashboard em vez de virar 500+CORS.
    void Page_Load(object sender, EventArgs e)
    {
        Response.AppendHeader("Access-Control-Allow-Origin", "*");
        Response.AppendHeader("Timing-Allow-Origin", "*");
        Response.AppendHeader("Cache-Control", "no-store");
        Response.ContentType = "application/json";

        int iters = 2000000, payloadKB = 200;
        try { int t; if (int.TryParse(ConfigurationManager.AppSettings["ComputeIters"], out t) && t > 0) iters = t; } catch {}
        try { int t; if (int.TryParse(ConfigurationManager.AppSettings["PayloadKB"], out t) && t >= 0) payloadKB = t; } catch {}

        // 1) io_ms: le os fragmentos da raiz. Se a identidade nao alcanca o NAS, cai no catch -> err.
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
            if (acc < 0) Response.Write(""); // impede o JIT de otimizar o loop pra fora
        } catch {}

        // 3) runtime/worker/bits/heap/ws: cada um guardado (trust restrito pode negar Process/WorkingSet)
        string runtime = "n/a", worker = "w3wp", bits = "";
        long heapMb = -1, wsMb = -1;
        try { runtime = ".NET CLR " + Environment.Version; } catch {}
        try { bits = Environment.Is64BitProcess ? "x64" : "x86"; } catch {}
        try { worker = Process.GetCurrentProcess().ProcessName; } catch {}
        try { heapMb = GC.GetTotalMemory(false) / 1048576; } catch {}
        try { wsMb = Process.GetCurrentProcess().WorkingSet64 / 1048576; } catch {}

        // backing: nas (physicalPath UNC) vs local (letra de drive) - pro dashboard auto-detectar o cenario
        string backing = "local";
        try { string ap = System.Web.Hosting.HostingEnvironment.ApplicationPhysicalPath; if (!string.IsNullOrEmpty(ap) && ap.StartsWith("\\\\")) backing = "nas"; } catch {}

        string filler = "";
        try { if (payloadKB > 0) filler = new string('x', payloadKB * 1024); } catch {}

        string errSafe = err.Replace("\\", "\\\\").Replace("\"", "'").Replace("\r", " ").Replace("\n", " ");
        var sb = new StringBuilder();
        sb.Append("{\"fragments\":").Append(k)
          .Append(",\"bytes\":").Append(bytes)
          .Append(",\"io_ms\":").Append(ioMs.ToString("F1"))
          .Append(",\"compute_ms\":").Append(cpuMs.ToString("F1"))
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
