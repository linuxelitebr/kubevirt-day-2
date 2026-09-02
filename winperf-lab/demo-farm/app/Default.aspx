<%@ Page Language="C#" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Diagnostics" %>
<%@ Import Namespace="System.Configuration" %>
<%@ Import Namespace="System.Text" %>
<script runat="server">
    // Arquetipo "dynamic-reads-root": a cada request le TODOS os fragmentos do content root (o padrao
    // do cliente: conteudo na raiz servido de UNC/DFS). io_ms = esse custo (muda NAS vs local, e NENHUM
    // cache do IIS cobre). compute_ms = trabalho local constante (linha de base). O filler comprimivel
    // deixa a compressao dinamica visivel no TAMANHO de rede (encodedBodySize).
    void Page_Load(object sender, EventArgs e)
    {
        // Headers: o dashboard roda em outra porta (outra origem). CORS libera ler o corpo;
        // Timing-Allow-Origin libera o browser expor o tamanho REAL transferido (pra ver a compressao).
        Response.AppendHeader("Access-Control-Allow-Origin", "*");
        Response.AppendHeader("Timing-Allow-Origin", "*");
        Response.AppendHeader("Cache-Control", "no-store");

        int iters;
        if (!int.TryParse(ConfigurationManager.AppSettings["ComputeIters"], out iters) || iters <= 0) iters = 2000000;
        int payloadKB;
        if (!int.TryParse(ConfigurationManager.AppSettings["PayloadKB"], out payloadKB) || payloadKB < 0) payloadKB = 200;

        // 1) io_ms: le todos os fragmentos da raiz (open+read+close por arquivo = chatty). NAS vs local aparece aqui.
        string dir = Server.MapPath("~/fragments");
        int k = 0; long bytes = 0;
        var swIo = Stopwatch.StartNew();
        if (Directory.Exists(dir))
            foreach (var f in Directory.GetFiles(dir, "*.frag")) { bytes += File.ReadAllBytes(f).LongLength; k++; }
        swIo.Stop();

        // 2) compute_ms: trabalho local constante (bate igual nos dois bracos, e' a linha de base realista)
        var swCpu = Stopwatch.StartNew();
        double acc = 0; for (int i = 1; i <= iters; i++) acc += Math.Sqrt(i);
        swCpu.Stop();

        // 3) filler comprimivel: com compressao dinamica ON o tamanho na rede despenca; OFF vai inteiro.
        string filler = payloadKB > 0 ? new string('x', payloadKB * 1024) : "";

        Response.ContentType = "application/json";
        var sb = new StringBuilder();
        sb.Append("{\"fragments\":").Append(k)
          .Append(",\"bytes\":").Append(bytes)
          .Append(",\"io_ms\":").Append(swIo.Elapsed.TotalMilliseconds.ToString("F1"))
          .Append(",\"compute_ms\":").Append(swCpu.Elapsed.TotalMilliseconds.ToString("F1"))
          .Append(",\"ts\":\"").Append(DateTime.UtcNow.ToString("o")).Append("\"")
          .Append(",\"filler\":\"").Append(filler).Append("\"}");
        Response.Write(sb.ToString());
    }
</script>
