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

  <!-- The rows of any web-player page: its cards (playlists, albums, artists)
       and its track rows, in the order the page draws them. -->
  <xsl:template match="/">
    <xsl:text>[</xsl:text>
    <xsl:for-each select="//main//*[@data-encore-id='card' or @data-testid='tracklist-row'][not(ancestor::*[@data-testid='tracklist-row'])]">
      <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
      <xsl:choose>
        <xsl:when test="@data-encore-id='card'"><xsl:call-template name="card"/></xsl:when>
        <xsl:otherwise><xsl:call-template name="track"><xsl:with-param name="n" select="position()"/></xsl:call-template></xsl:otherwise>
      </xsl:choose>
    </xsl:for-each>
    <xsl:text>]</xsl:text>
  </xsl:template>
  <xsl:template name="card">
    <!-- aria-labelledby is card-title-spotify:KIND:ID-N -->
    <xsl:variable name="uri" select="substring-before(concat(substring-after(@aria-labelledby, 'card-title-'), '-'), '-')"/>
    <xsl:variable name="shelf" select="normalize-space(ancestor::section[@aria-label][1]/@aria-label)"/>
    <xsl:text>{&quot;kind&quot;:</xsl:text>
    <xsl:call-template name="str"><xsl:with-param name="val" select="substring-before(substring-after($uri, 'spotify:'), ':')"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'key'"/><xsl:with-param name="val" select="concat($uri, '|', $shelf)"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'href'"/><xsl:with-param name="val" select="concat('/', substring-before(substring-after($uri, 'spotify:'), ':'), '/', substring-after(substring-after($uri, 'spotify:'), ':'))"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'name'"/><xsl:with-param name="val" select="(.//*[@data-encore-id='cardTitle'])[1]"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'sub'"/><xsl:with-param name="val" select="(.//*[@data-encore-id='cardSubtitle'])[1]"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'art'"/><xsl:with-param name="val" select="(.//img/@src)[1]"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'shelf'"/><xsl:with-param name="val" select="$shelf"/></xsl:call-template>
    <xsl:text>}</xsl:text>
  </xsl:template>
  <xsl:template name="track">
    <xsl:param name="n"/>
    <xsl:variable name="link" select="(.//a[contains(@href,'/track/')])[1]"/>
    <xsl:text>{&quot;kind&quot;:&quot;track&quot;</xsl:text>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'key'"/><xsl:with-param name="val" select="concat($link/@href, '#', $n)"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'href'"/><xsl:with-param name="val" select="$link/@href"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'name'"/><xsl:with-param name="val" select="$link"/></xsl:call-template>
    <xsl:text>,&quot;artists&quot;:</xsl:text><xsl:call-template name="artists"/>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'album'"/><xsl:with-param name="val" select="(.//a[contains(@href,'/album/')])[1]"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'art'"/><xsl:with-param name="val" select="(.//img/@src)[1]"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'index'"/><xsl:with-param name="val" select="(.//div[@role='gridcell'][1]//span)[1]"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'duration'"/><xsl:with-param name="val" select="(.//div[@role='gridcell'][last()]//*[@data-encore-id='text'])[1]"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'play'"/><xsl:with-param name="val" select="(.//div[@role='gridcell'][1]//button/@aria-label)[1]"/></xsl:call-template>
    <xsl:text>}</xsl:text>
  </xsl:template>
</xsl:stylesheet>
