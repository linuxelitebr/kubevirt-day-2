<%@ Application Language="C#" %>
<%@ Import Namespace="System.Configuration" %>
<script runat="server">
    // Modo "app pesada de memoria" (reproduz o padrao do cliente que pede 16 vCPU / 96 GB):
    // no start do pool, aloca MemLoadMB e SEGURA a referencia (simula o working set gigante que o app
    // carrega). Isso encarece o cold-start (a 1a request espera o carregamento) e deixa a RAM parada.
    // Os blocos tem tamanhos variados (1-4 MB) pra caírem no LOH e FRAGMENTAR o heap (como um app real
    // que aloca/segura muitos objetos grandes). MemLoadMB = 0 desliga (comportamento leve, o default).
    static object _held;
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
            int sizeMB = 1 + rnd.Next(4);                 // 1-4 MB -> vai pro Large Object Heap e fragmenta
            var b = new byte[sizeMB * 1024 * 1024];
            b[0] = 1; b[b.Length - 1] = 1;                // toca as paginas pra virarem working set de verdade
            chunks.Add(b);
            done += sizeMB;
        }
        _held = chunks;                                    // segura pra o GC nao coletar (working set parado)
        Application["MemLoadMs"] = sw.ElapsedMilliseconds;  // custo de cold-start do carregamento
        Application["MemLoadMB"] = done;
    }
</script>
