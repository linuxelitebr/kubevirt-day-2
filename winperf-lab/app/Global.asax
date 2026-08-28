<%@ Application Language="C#" %>
<script runat="server">
    // Application_Start roda UMA vez por start do app pool.
    // Sem warm-up (App Init), ele roda na PRIMEIRA request do usuario -> essa request paga o custo (cold-start).
    // Com warm-up (App Init/preload), roda no start do pool ANTES do usuario -> a primeira request ja vem quente.
    //
    // O custo aqui e' CPU-bound com WORK FIXO (numero de iteracoes), NAO tempo fixo.
    // Isso e' de proposito: sob contencao de CPU entre VMs co-locadas, o mesmo work leva MAIS tempo de parede,
    // que e' exatamente o efeito +2s que queremos reproduzir e medir.
    void Application_Start(object sender, EventArgs e)
    {
        int iters;
        if (!int.TryParse(System.Configuration.ConfigurationManager.AppSettings["WarmupIterations"], out iters) || iters <= 0)
            iters = 40000000; // ajuste no web.config para calibrar ~2-4s numa VM ociosa

        var sw = System.Diagnostics.Stopwatch.StartNew();
        // MULTI-THREAD: satura todos os vCPUs. Cada thread faz 'iters' ops, entao o tempo de parede
        // isolado fica ~igual ao single-thread, mas todos os cores ficam ocupados -> a contencao entre
        // VMs co-locadas (Exp 2) passa a aparecer. Sob um vizinho barulhento no mesmo node, as threads
        // disputam cores fisicos e o mesmo work leva mais tempo de parede.
        double total = 0;
        object gate = new object();
        System.Threading.Tasks.Parallel.For(0, System.Environment.ProcessorCount, delegate(int t) {
            double acc = 0;
            for (int i = 1; i <= iters; i++) { acc += System.Math.Sqrt(i) * 1.0000001; }
            lock (gate) { total += acc; }
        });
        sw.Stop();

        Application["WarmupMs"]  = sw.ElapsedMilliseconds;
        Application["WarmupAcc"] = total; // impede o JIT de otimizar o loop pra fora
        Application["StartedUtc"] = System.DateTime.UtcNow.ToString("o");
    }
</script>
