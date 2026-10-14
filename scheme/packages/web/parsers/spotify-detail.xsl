<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="text" encoding="UTF-8" omit-xml-declaration="yes"/>
  <xsl:strip-space elements="*"/>
  <!-- JSON strings: backslashes first, then quotes -->
  <xsl:template name="esc"><xsl:param name="s"/><xsl:choose><xsl:when test="contains($s, '\')"><xsl:call-template name="escq"><xsl:with-param name="s" select="substring-before($s, '\')"/></xsl:call-template><xsl:text>\\</xsl:text><xsl:call-template name="esc"><xsl:with-param name="s" select="substring-after($s, '\')"/></xsl:call-template></xsl:when><xsl:otherwise><xsl:call-template name="escq"><xsl:with-param name="s" select="$s"/></xsl:call-template></xsl:otherwise></xsl:choose></xsl:template>
  <xsl:template name="escq"><xsl:param name="s"/><xsl:choose><xsl:when test="contains($s, '&quot;')"><xsl:value-of select="substring-before($s, '&quot;')"/><xsl:text>\&quot;</xsl:text><xsl:call-template name="escq"><xsl:with-param name="s" select="substring-after($s, '&quot;')"/></xsl:call-template></xsl:when><xsl:otherwise><xsl:value-of select="$s"/></xsl:otherwise></xsl:choose></xsl:template>
  <xsl:template name="str"><xsl:param name="val"/><xsl:text>&quot;</xsl:text><xsl:call-template name="esc"><xsl:with-param name="s" select="normalize-space($val)"/></xsl:call-template><xsl:text>&quot;</xsl:text></xsl:template>
  <xsl:template name="field"><xsl:param name="key"/><xsl:param name="val"/><xsl:text>,&quot;</xsl:text><xsl:value-of select="$key"/><xsl:text>&quot;:</xsl:text><xsl:call-template name="str"><xsl:with-param name="val" select="$val"/></xsl:call-template></xsl:template>
  <!-- every artist link of a row, as one line -->
  <xsl:template name="artists"><xsl:text>&quot;</xsl:text><xsl:for-each select=".//a[contains(@href,'/artist/')]"><xsl:if test="position() &gt; 1"><xsl:text>, </xsl:text></xsl:if><xsl:call-template name="esc"><xsl:with-param name="s" select="normalize-space(.)"/></xsl:call-template></xsl:for-each><xsl:text>&quot;</xsl:text></xsl:template>

  <xsl:template name="kid"><xsl:param name="text"/><xsl:param name="href"/><xsl:text>,&quot;children&quot;:[{&quot;tag&quot;:&quot;c-field&quot;,&quot;text&quot;:</xsl:text><xsl:call-template name="str"><xsl:with-param name="val" select="$text"/></xsl:call-template><xsl:text>,&quot;href&quot;:</xsl:text><xsl:call-template name="str"><xsl:with-param name="val" select="$href"/></xsl:call-template><xsl:text>}]</xsl:text></xsl:template>
  <!-- One playlist, album, artist or song page: a hero that heads it, then its
       tracks and its shelves of cards, in the order the page draws them. -->
  <xsl:template match="/">
    <xsl:variable name="head" select="(//main//*[@data-testid='entity-header'])[1]"/>
    <xsl:variable name="name" select="($head//*[@data-testid='entityTitle' or @data-testid='adaptiveEntityTitle'])[1]"/>
    <xsl:variable name="style" select="(//main//*[contains(@style,'--background-base:')])[1]/@style"/>
    <xsl:text>{&quot;title&quot;:&quot;&quot;,&quot;tabs&quot;:[null,{&quot;id&quot;:&quot;main&quot;,&quot;label&quot;:&quot;Tracks&quot;,&quot;active&quot;:&quot;yes&quot;}],&quot;section&quot;:[null</xsl:text>
    <xsl:text>,{&quot;tag&quot;:&quot;c-item&quot;,&quot;class&quot;:&quot;sp-hero&quot;,&quot;component&quot;:&quot;spotify/hero&quot;</xsl:text>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'logo'"/><xsl:with-param name="val" select="(//main//img[@sizes])[1]/@src"/></xsl:call-template>

    <xsl:call-template name="field"><xsl:with-param name="key" select="'tone'"/><xsl:with-param name="val" select="substring(substring-before(concat(substring-after($style, '--background-base:'), ';'), ';'), 1, 8)"/></xsl:call-template>
    <!-- the label over the title: Album, Public Playlist, Single -->
    <xsl:call-template name="field"><xsl:with-param name="key" select="'tier'"/><xsl:with-param name="val" select="$name/preceding::span[@data-encore-id='text'][ancestor::*[@data-testid='entity-header']][1]"/></xsl:call-template>
    <xsl:text>,&quot;tags&quot;:[</xsl:text>

    <xsl:for-each select="$head//*[@data-encore-id='text' or @data-testid='release-date' or (self::span and @aria-hidden='true' and contains(., 'listeners'))][not(@data-separator)][not(ancestor::*[@data-testid='entityTitle' or @data-testid='adaptiveEntityTitle'])][not(descendant::*[@data-encore-id='text'])][normalize-space(.) != '']">
      <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
      <xsl:call-template name="str"><xsl:with-param name="val" select="."/></xsl:call-template>
    </xsl:for-each>
    <!-- under an album's tracks: the whole release date, then the label's line -->
    <xsl:variable name="released" select="(//main//p[@data-encore-id='text'][contains(., ', ')][string-length(normalize-space(.)) &lt; 20][number(substring(normalize-space(.), string-length(normalize-space(.)) - 3)) = number(substring(normalize-space(.), string-length(normalize-space(.)) - 3))])[1]"/>
    <xsl:if test="$released"><xsl:text>,</xsl:text><xsl:call-template name="str"><xsl:with-param name="val" select="concat('Released ', normalize-space($released))"/></xsl:call-template></xsl:if>
    <xsl:variable name="label" select="(//main//p[@data-encore-id='type'][starts-with(normalize-space(.), '℗')])[1]"/>
    <xsl:if test="$label"><xsl:text>,</xsl:text><xsl:call-template name="str"><xsl:with-param name="val" select="$label"/></xsl:call-template></xsl:if>
    <xsl:text>]</xsl:text>
    <xsl:call-template name="kid"><xsl:with-param name="text" select="$name"/><xsl:with-param name="href" select="''"/></xsl:call-template>
    <xsl:text>}</xsl:text>

    <xsl:for-each select="//main//*[@data-testid='tracklist-row' or @data-encore-id='card' or (self::section and @data-testid='component-shelf')][not(ancestor::*[@data-testid='tracklist-row'])]">
      <xsl:text>,</xsl:text>
      <xsl:choose>
        <xsl:when test="self::section">
          <xsl:text>{&quot;tag&quot;:&quot;c-heading&quot;,&quot;text&quot;:</xsl:text><xsl:call-template name="str"><xsl:with-param name="val" select="@aria-label"/></xsl:call-template><xsl:text>}</xsl:text>
        </xsl:when>
        <xsl:when test="@data-encore-id='card'">
          <xsl:variable name="uri" select="substring-before(concat(substring-after(@aria-labelledby, 'card-title-'), '-'), '-')"/>
          <xsl:text>{&quot;tag&quot;:&quot;c-item&quot;,&quot;class&quot;:&quot;sp-tile&quot;,&quot;component&quot;:&quot;spotify/tile&quot;</xsl:text>
          <xsl:call-template name="field"><xsl:with-param name="key" select="'logo'"/><xsl:with-param name="val" select="(.//img/@src)[1]"/></xsl:call-template>
          <xsl:call-template name="field"><xsl:with-param name="key" select="'tier'"/><xsl:with-param name="val" select="substring-before(substring-after($uri, 'spotify:'), ':')"/></xsl:call-template>
          <xsl:call-template name="field"><xsl:with-param name="key" select="'href'"/><xsl:with-param name="val" select="concat('/', substring-before(substring-after($uri, 'spotify:'), ':'), '/', substring-after(substring-after($uri, 'spotify:'), ':'))"/></xsl:call-template>
          <xsl:text>,&quot;tags&quot;:[</xsl:text><xsl:call-template name="str"><xsl:with-param name="val" select="(.//*[@data-encore-id='cardSubtitle'])[1]"/></xsl:call-template><xsl:text>]</xsl:text>
          <xsl:call-template name="kid"><xsl:with-param name="text" select="(.//*[@data-encore-id='cardTitle'])[1]"/><xsl:with-param name="href" select="concat('/', substring-before(substring-after($uri, 'spotify:'), ':'), '/', substring-after(substring-after($uri, 'spotify:'), ':'))"/></xsl:call-template>
          <xsl:text>}</xsl:text>
        </xsl:when>

        <xsl:otherwise>
          <xsl:variable name="link" select="(.//a[contains(@href,'/track/')])[1]"/>
          <xsl:text>{&quot;tag&quot;:&quot;c-item&quot;,&quot;class&quot;:&quot;sp-track&quot;,&quot;component&quot;:&quot;spotify/track&quot;</xsl:text>
          <xsl:call-template name="field"><xsl:with-param name="key" select="'logo'"/><xsl:with-param name="val" select="(.//img/@src)[1]"/></xsl:call-template>
          <xsl:call-template name="field"><xsl:with-param name="key" select="'tier'"/><xsl:with-param name="val" select="(.//div[@role='gridcell'][1]//span)[1]"/></xsl:call-template>
          <xsl:call-template name="field"><xsl:with-param name="key" select="'href'"/><xsl:with-param name="val" select="$link/@href"/></xsl:call-template>
          <xsl:call-template name="field"><xsl:with-param name="key" select="'play'"/><xsl:with-param name="val" select="(.//div[@role='gridcell'][1]//button/@aria-label)[1]"/></xsl:call-template>
          <xsl:text>,&quot;tags&quot;:[</xsl:text><xsl:call-template name="artists"/><xsl:text>,</xsl:text>
          <xsl:call-template name="str"><xsl:with-param name="val" select="(.//a[contains(@href,'/album/')])[1]"/></xsl:call-template><xsl:text>,</xsl:text>
          <xsl:call-template name="str"><xsl:with-param name="val" select="(.//div[@role='gridcell'][last()]//*[@data-encore-id='text'])[1]"/></xsl:call-template><xsl:text>]</xsl:text>
          <xsl:call-template name="kid"><xsl:with-param name="text" select="$link"/><xsl:with-param name="href" select="$link/@href"/></xsl:call-template>
          <xsl:text>}</xsl:text>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:for-each>
    <xsl:text>]}</xsl:text>
  </xsl:template>
</xsl:stylesheet>
