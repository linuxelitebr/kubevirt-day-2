<%@ Page Language="C#" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Diagnostics" %>
<%@ Import Namespace="System.Configuration" %>
<script runat="server">
    // Arquetipo "dynamic-reads-root": a cada request, le TODOS os fragmentos do content root.
    // Isso simula uma app IIS servindo includes/assets/dados da raiz por request - o padrao do
    // cliente (conteudo na raiz, servido de UNC/DFS). E' o custo que MUDA quando a raiz esta no
    // NAS vs disco local, e que NENHUM cache do IIS cobre (e' I/O de arquivo do proprio app).
    //
    // Reporta io_ms (sensivel a NAS-vs-local) separado de compute_ms (trabalho de backend
    // CONSTANTE e local, a linha de base realista que bate igual nos dois bracos).
    void Page_Load(object sender, EventArgs e)
    {
        int iters;
        if (!int.TryParse(ConfigurationManager.AppSettings["ComputeIters"], out iters) || iters <= 0)
            iters = 2000000;

        string dir = Server.MapPath("~/fragments");
        int k = 0; long bytes = 0;

        var swIo = Stopwatch.StartNew();
        if (Directory.Exists(dir))
        {
            foreach (var f in Directory.GetFiles(dir, "*.frag"))
            {
                bytes += File.ReadAllBytes(f).LongLength;   // open + read + close por arquivo (chatty)
                k++;
            }
        }
        swIo.Stop();

        var swCpu = Stopwatch.StartNew();
        double acc = 0;
        for (int i = 1; i <= iters; i++) acc += Math.Sqrt(i);   // trabalho local constante
        swCpu.Stop();

        Response.ContentType = "application/json";
        Response.Write(
            "{\"site\":\"" + Request.ServerVariables["INSTANCE_ID"] +
            "\",\"fragments\":" + k +
            ",\"bytes\":" + bytes +
            ",\"io_ms\":" + swIo.Elapsed.TotalMilliseconds.ToString("F1") +
            ",\"compute_ms\":" + swCpu.Elapsed.TotalMilliseconds.ToString("F1") +
            ",\"acc\":" + acc.ToString("F0") +
            ",\"ts\":\"" + DateTime.UtcNow.ToString("o") + "\"}");
    }
</script>
