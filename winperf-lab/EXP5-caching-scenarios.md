# Exp 5: onde o cache do .NET/IIS salva o UNC, e onde não salva

Reconcilia a afirmação "no .NET, cache significa que ele não fica batendo no disco/UNC a cada request" com o caso real. Verificado contra fonte primária (Microsoft Learn/IIS, KB, [MS-SMB2]) com passo adversarial. **A frase é verdadeira num sentido estreito e falsa exatamente nos casos que produzem o sintoma.**

## O escopo, em uma linha

- **VERDADE** só pra: executar a lógica de página **já compilada** num worker quente (roda de memória/local, não re-lê do UNC), e pra respostas/objetos explicitamente mantidos num output cache quente ou no `Cache` do ASP.NET.
- **FALSO** pra: **cold-start** (compila-do-UNC na reciclagem/primeira request), **I/O de arquivo do próprio app** por request na raiz (round-trip SMB não-cacheado), **estático de UNC no HTTP.sys** (excluído por padrão), respostas **autenticadas/com query-string/grandes/comprimidas**, e enquanto o cache **não esquentou**.

"Cache do .NET" na verdade são várias caches distintas (HTTP.sys kernel, output cache user-mode, file cache user-mode, e as caches in-process do ASP.NET). Qual se aplica é o que decide o diagnóstico.

## A matriz de cenários

| # | Cenário | Camada de cache | Salva o round-trip UNC? | Fronteira |
|---|---|---|---|---|
| 1 | **Cold-start** (start do pool, reciclagem de AppDomain, idle timeout, 1ª request após restart) | nenhuma quente ainda | **NÃO** | Lê source + `bin` do `physicalPath` por SMB, compila, aí faz shadow-copy local. Toda reciclagem re-paga o read SMB assinado + compilação. **É a assinatura do "primeira resposta lenta".** `numRecompilesBeforeAppRestart` default 15. [dynamic compilation](https://learn.microsoft.com/en-us/previous-versions/aspnet/ms366723(v=vs.100)), [shadow copy](https://learn.microsoft.com/en-us/dotnet/framework/app-domains/shadow-copy-assemblies) |
| 2 | **Execução de página compilada, quente** | assembly compilado em `Temporary ASP.NET Files` (LOCAL) + `bin` shadow-copiado (LOCAL) | **SIM** | A classe de página roda de assembly local em memória. Executar o código NÃO re-lê o DLL do UNC. **É a metade verdadeira** da afirmação do dono. |
| 3 | **Estático cacheável quente** (anônimo, sem query, pequeno, GET) na raiz UNC | HTTP.sys kernel cache | **NÃO, por padrão** | O HTTP.sys não cacheia arquivo estático quando "é um arquivo UNC e a chave `DoDirMonitoringForUnc` não está habilitada" (default 0). Raiz no NAS derrota o caminho de kernel. [KB 817445](https://learn.microsoft.com/en-us/troubleshoot/developer/webapps/iis/www-modules-features/instances-httpsys-not-cache) |
| 4 | **Resposta autenticada / query-string / grande / comprimida** | HTTP.sys (só valeria pra estático anônimo) | **NÃO** | Kernel cache exclui não-anônimo (`Authorization`), query strings, corpo de entidade, > 256 KB, e compressão dinâmica ligada. Output cache user-mode só após `frequentHitThreshold` (2 hits em 10s) e é ruim pra conteúdo personalizado. [KB 817445](https://learn.microsoft.com/en-us/troubleshoot/developer/webapps/iis/www-modules-features/instances-httpsys-not-cache), [IIS 7 Output Caching](https://learn.microsoft.com/en-us/iis/manage/managing-performance-settings/configure-iis-7-output-caching) |
| 5 | **Página dinâmica que LÊ a raiz pra montar a resposta** (template/relatório/dado por request) | `Cache` do ASP.NET só se o dev populou | **NÃO por padrão** | As caches do IIS guardam a RESPOSTA HTTP, não as chamadas de arquivo do app. Nada embrulha `File.Open`/`ReadAllText`. A leitura vai pro redirector SMB a não ser que o dev tenha metido o conteúdo no `System.Web.Cache`. (Inferência arquitetural, não uma frase citada.) |
| 6 | **I/O de arquivo do app sobre UNC, worker quente, sem cache do app** | lease do cliente SMB2, não cache do IIS | **EM PARTE, e depende do lease** | O open é sempre um SMB2 CREATE que o servidor processa; os DADOS só vêm do cache do cliente enquanto há lease de READ, e o read-caching de diretório é revogado a cada mudança de metadado. Signing assina cada round-trip. **Elo mais fraco desta análise:** o leasing do [MS-SMB2] não está URL-citado, então trate "reads quentes podem custar round-trip" como raciocínio, não fato citado. Vale MEDIR. |
| 7 | **Tráfego de coerência FCN** (FileChangesMonitor vigiando a árvore) | os próprios monitores de diretório (armados no init) | **SIM em steady-state (push, não poll por-request); NÃO no cold-start nem em mudança em massa** | FCN é `ReadDirectoryChangesW` = um SMB2 CHANGE_NOTIFY pendente por diretório, então servir request não adiciona round-trip de detecção. Mas armar cada monitor no cold-start custa round-trips + um work context por diretório; overflow do buffer sobre a rede → AppDomain descarregado → volta pro cold-start. [FCN monitored files](https://learn.microsoft.com/en-us/archive/blogs/tmarq/asp-net-file-change-notifications-exactly-which-files-and-directories-are-monitored), [KB 911272](https://support.microsoft.com/en-us/help/911272) |
| 8 | **Concorrência / concentração de work-items SMB** (muitos subdiretórios, muitos CHANGE_NOTIFY pendentes numa conexão SMB) | work contexts do servidor SMB | **NÃO (e pode derrubar o app)** | "Conforme o número de subdiretórios cresce, o número de notificações cresce. Cada notificação usa um comando SMB." Exaustão vira "network BIOS command limit reached", 500s. Os knobs `MaxMpxCt`/`MaxWorkItems` são da era **Windows Server 2003** (o lanmanserver os ignora no 2008+), então NÃO aplique num NAS moderno. [KB 911272](https://support.microsoft.com/en-us/help/911272) |
| 9 | **Modelo CGI** (processo-por-request, ex.: CGI clássico num FS de rede) | nenhuma persistente: sem worker vivo | **NÃO, nunca** | CGI forka um processo por request e ele morre no fim, então nenhum cache in-process sobrevive. Com executável + raiz num FS de rede, cada request paga spawn + load da imagem + init pela rede. **É cold-start permanente, e o sintoma é lentidão UNIFORME**, não só a 1ª resposta. É o CONTRA-EXEMPLO do caso .NET. [IIS CGI](https://learn.microsoft.com/en-us/iis/configuration/system.webserver/cgi), [mod_cgid](https://httpd.apache.org/docs/2.4/mod/mod_cgid.html), [RFC 3875](https://www.rfc-editor.org/rfc/rfc3875) |

## O diagnóstico que sai da matriz (o pulo do gato)

A migração **não** adicionou um custo por-request que "o cache remove". Ela adicionou latência de rede (referral DFS + sessão SMB + round-trips assinados) exatamente às operações que o cache do IIS/.NET **nunca** cobriu: cold-start compilando-do-UNC (#1), estático-de-UNC não-cacheado no kernel (#3), e o I/O de arquivo do próprio app por request (#5, #6). **Por isso o sintoma é primeira-resposta-lenta-e-rápida-depois.** Se fosse lentidão uniforme em toda request, o ponteiro seria o modelo CGI (#9), que não guarda worker quente nenhum.

**Fingerprint testável:** primeira-resposta-lenta-depois-rápida = cold-start-do-UNC (#1). Toda-request-lenta = ou o app lê a raiz por request (#5) ou é CGI-like (#9). O formato do sintoma diz o cenário.

## O CGI-sobre-NFS (a experiência do Apache/COBOL) é o irmão mais severo

CGI forka um processo por request que morre no fim: nada application-level sobrevive. Ponha executável + interpretador + libs + document root no NFS e cada request paga spawn + load da imagem + conteúdo pela rede, sem processo longo pra amortizar, e num cluster keepalived o cache de FS de cada node é separado, então nenhum node esquenta. É **cold-start permanente**, e foi por isso que disco local resolveu na hora. Um modelo de processo residente (ASP.NET in-process, ou FastCGI reusado até `instanceMaxRequests`) só faz cold-start no start/reciclagem do worker e fica quente no meio, então o fingerprint dele é "1ª resposta lenta, rápida depois". CGI-sobre-NFS seria uniformemente lento. Mesma causa-raiz (o cache assumido não cobre acesso de arquivo de rede por request), o .NET só limita o dano ao warm-up + o primeiro toque no UNC.

## Como os cenários viram os arquétipos do demo

- **static-cacheable** → cenários #2/#3: mostra o cache funcionando (execução) E que estático de UNC ainda erra o kernel cache por padrão.
- **cold-start** → cenário #1: o fingerprint real do cliente. Força reciclagem, mede a 1ª resposta, UNC vs local.
- **dynamic-reads-root** → cenários #5/#6: I/O de arquivo por request, não-cacheado, UNC vs local.
- **cgi-like** → cenário #9: o contra-exemplo, lentidão uniforme.
- **concorrência** → #7/#8: sobe a carga do consumidor e mostra a contenção do concentrador.

## Correções de honestidade (não repita errado)

- Os knobs `MaxMpxCt`/`MaxWorkItems`/`MaxCmds` são **Windows Server 2003**; ignorados no 2008+. O mecanismo (um work context por notify pendente) transfere; os valores não. Não aplique num NAS moderno.
- O leasing SMB2 que decide se um read quente vai no fio ou no cache do cliente **não está citado em primária**. Trate como raciocínio e **meça** (é o que o `bench-smb.ps1` faz).
- O `DoDirMonitoringForUnc` é da era IIS6/metabase; que ele ainda governe o HTTP.sys em IIS moderno **não** foi confirmado numa doc atual. A KB 817445 (mantida, ms.date 2024) ainda publica a chave, mas trate a aplicabilidade no IIS 10 como a verificar.
- O fix concreto pro #1: **precompilar** o site (`aspnet_compiler`, non-updateable) evita a compilação na 1ª request; e reduzir a reciclagem (não editar web.config/bin/App_Code no share, subir idle-timeout).
