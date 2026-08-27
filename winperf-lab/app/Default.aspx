<%@ Page Language="C#" %>
<script runat="server">
    protected void Page_Load(object sender, EventArgs e)
    {
        Response.ContentType = "text/plain";
        Response.Write("OK " + System.DateTime.UtcNow.ToString("o") + "\n");
        Response.Write("app_started_utc=" + (Application["StartedUtc"] ?? "n/a") + "\n");
        Response.Write("warmup_ms=" + (Application["WarmupMs"] ?? "n/a") + "\n");
    }
</script>
