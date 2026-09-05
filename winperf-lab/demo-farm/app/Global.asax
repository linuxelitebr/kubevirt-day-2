<%@ Application Language="C#" %>
<%@ Import Namespace="System.Configuration" %>
<script runat="server">
    // Modo "app pesada de memoria" (reproduz o padrao do cliente que pede 16 vCPU / 96 GB):
    // no start do pool, aloca MemLoadMB e SEGURA a referencia em Application["memHold"] (simula o cache
    // grande carregado na subida). Encarece o cold-start e deixa a RAM parada. Blocos de 1-4 MB caem no
    // LOH e fragmentam, como um app real que segura muitos objetos grandes. MemLoadMB = 0 desliga.
    // O Default.aspx le esse buffer no ScanMB (pra tornar a app memory-bound e NUMA-sensivel).
    void Application_Start(object sender, EventArgs e)
    {
        int mb;
        if (!int.TryParse(ConfigurationManager.AppSettings["MemLoadMB"], out mb) || mb <= 0) return;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var chunks = new System.Collections.Generic.List<byte[]>();
        var rnd = new Random(1);
        int done = 0;
        while (done < mb)
        {
            int sizeMB = 1 + rnd.Next(4);                 // 1-4 MB -> Large Object Heap, fragmenta
            var b = new byte[sizeMB * 1024 * 1024];
            b[0] = 1; b[b.Length - 1] = 1;                // toca as paginas (vira working set real)
            chunks.Add(b);
            done += sizeMB;
        }
        Application["memHold"]  = chunks;                  // segura pra o GC nao coletar
        Application["memLoadMs"] = sw.ElapsedMilliseconds;
        Application["memLoadMB"] = done;
    }
</script>
