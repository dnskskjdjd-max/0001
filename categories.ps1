# Categorias de mercado compartidas por tracker.ps1 y copier.ps1 (se cargan con: . .\categories.ps1)
# Categorias: se prueba en orden contra "slug eventSlug titulo"; la primera regla que coincide gana.
# IDENTICAS a CATEGORY_RULES en dashboard.html: si cambias una, cambia la otra.
# (Este archivo se guarda con BOM UTF-8 para que PowerShell 5.1 lea bien las tildes.)
$CategoryRules = @(
    @('eSports',                        '(^|\s)(cs2|csgo|val|lol|dota2?|ow|r6|rl|sc2|pubg|apex|mlbb|hok|codm|cod|fortnite|wr)-|Counter-Strike|Valorant|League of Legends|LoL:|Dota|Overwatch|Rainbow Six|Rocket League|Call of Duty|Mobile Legends|PUBG|Apex Legends|\(BO\d\)'),
    @('NFL',                            '(^|\s)nfl-|\bNFL\b|Super Bowl'),
    @('Fútbol americano universitario', '(^|\s)cfb-|College Football|Heisman'),
    @('Béisbol (MLB)',                  '(^|\s)mlb-|\bMLB\b|World Series|first inning'),
    @('Básquet',                        '(^|\s)(nba|wnba|cbb)-|\b(NBA|WNBA)\b|March Madness'),
    @('Hockey (NHL)',                   '(^|\s)nhl-|\bNHL\b|Stanley Cup'),
    @('Fútbol',                         '(^|\s)(epl|ucl|uel|uecl|conl|unl|mls|lal|sea|bun|fl1|ser|mex|bra|arg|por|ned|tur|fifa|wc|cdr|lib|sud)-|win on \d{4}-\d{2}-\d{2}|Premier League|Champions League|La ?Liga|Ballon d|Serie A|Bundesliga|Ligue 1|World Cup|\bMLS\b|\bFC\b'),
    @('Tenis',                          '(^|\s)(atp|wta)-|Wimbledon|US Open|Roland Garros|Australian Open'),
    @('Combate (UFC / boxeo)',          '(^|\s)(ufc|box|boxing)-|\bUFC\b|boxing'),
    @('F1 / motor',                     '(^|\s)(f1|nascar|indy)-|Grand Prix|Formula 1|\bF1\b|NASCAR'),
    @('Otros deportes',                 '(^|\s)[a-z0-9]+-[a-z0-9]+-[a-z0-9]+-\d{4}-\d{2}-\d{2}'),
    @('Cripto',                         'bitcoin|\bbtc\b|ethereum|\beth\b|eth-|solana|crypto|\bfdv\b|token|airdrop|\bxrp\b|doge|memecoin|stablecoin|coinbase|binance|microstrategy|Extended'),
    @('Economía / Fed',                 'fed-|\bfed\b|fomc|interest rate|rate cut|rate hike|bps|inflation|\bcpi\b|recession|\bgdp\b|unemployment|tariff|jobs report|nonfarm|S&P|nasdaq|dow jones|treasury|yield'),
    @('Materias primas',                'crude|\boil\b|gold|silver|natural gas|copper|wheat|\(GC\)|\(CL\)'),
    @('Política / elecciones',          'election|elected|president|senate|house seat|governor|mayor|prime minister|chancellor|parliament|nominee|nomination|midterm|democrat|republican|primary|cabinet|impeach|supreme court|resign|out as|out by|out before|approval rating|referendum|coalition|congress|signed into law|retirement|\bpope\b|nobel'),
    @('Geopolítica',                    'iran|russia|ukraine|israel|china|nato|\bwar\b|ceasefire|invade|invasion|strait|blockade|taiwan|gaza|hamas|hezbollah|houthi|strike on|military|nuclear|missile|cuba|venezuela|north korea|troops|sanction|clash|greenland'),
    @('Empresas / tecnología',          'openai|chatgpt|\bgpt\b|\bai\b|gemini|anthropic|apple|tesla|nvidia|spacex|starship|google|microsoft|\bmeta\b|acquire|\bipo\b|merger|earnings|gamestop|ebay|amazon'),
    @('Cultura / entretenimiento',      'oscar|grammy|emmy|golden globe|movie|box office|album|spotify|tiktok|taylor swift|netflix|billboard|youtube|mrbeast|eurovision|stranger things|\bgta\b|episode')
)
$SportCategories = @('NFL', 'Fútbol americano universitario', 'Béisbol (MLB)', 'Básquet', 'Hockey (NHL)', 'Fútbol', 'Tenis', 'Combate (UFC / boxeo)', 'F1 / motor', 'Otros deportes')
function Get-Category($text) {
    foreach ($r in $CategoryRules) { if ($text -match $r[1]) { return $r[0] } }
    return 'Otros'
}
# Filtro de categoria de la estrategia: 'all', 'no-esports', 'sports' (deportes sin eSports) o una categoria concreta
function Test-CategoryAllowed($cat, $filter) {
    if (-not $filter -or $filter -eq 'all') { return $true }
    if ($filter -eq 'no-esports') { return $cat -ne 'eSports' }
    if ($filter -eq 'sports') { return $SportCategories -contains $cat }
    return $cat -eq $filter
}
