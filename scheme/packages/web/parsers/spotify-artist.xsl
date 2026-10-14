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

  <!-- text with its line breaks kept, each line escaped -->
  <xsl:template name="lines"><xsl:param name="s"/><xsl:choose><xsl:when test="contains($s, '&#10;')"><xsl:call-template name="esc"><xsl:with-param name="s" select="substring-before($s, '&#10;')"/></xsl:call-template><xsl:text>\n</xsl:text><xsl:call-template name="lines"><xsl:with-param name="s" select="substring-after($s, '&#10;')"/></xsl:call-template></xsl:when><xsl:otherwise><xsl:call-template name="esc"><xsl:with-param name="s" select="$s"/></xsl:call-template></xsl:otherwise></xsl:choose></xsl:template>

  <!-- An artist's page, for the Now Playing page: who they are, what they
       made, and where they play next. -->
  <xsl:template match="/">
    <xsl:variable name="about" select="(//main//h2[normalize-space(.)='About']/following::button[1])[1]"/>
    <xsl:variable name="style" select="$about/@style"/>
    <xsl:text>{&quot;name&quot;:</xsl:text>
    <xsl:call-template name="str"><xsl:with-param name="val" select="(//main//*[@data-testid='adaptiveEntityTitle' or @data-testid='entityTitle'])[1]"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'image'"/><xsl:with-param name="val" select="substring-before(substring-after($style, 'url(&quot;'), '&quot;)')"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'listeners'"/><xsl:with-param name="val" select="($about//*[contains(., 'monthly listeners')][not(*[contains(., 'monthly listeners')])])[1]"/></xsl:call-template>
    <xsl:call-template name="field"><xsl:with-param name="key" select="'verified'"/><xsl:with-param name="val" select="substring('yes', 1, 3 * number(boolean(//main//button[@aria-label='Verified by Spotify'])))"/></xsl:call-template>
    <xsl:text>,&quot;bio&quot;:&quot;</xsl:text><xsl:call-template name="lines"><xsl:with-param name="s" select="string(($about//div[@dir='auto'])[1])"/></xsl:call-template><xsl:text>&quot;</xsl:text>

    <xsl:text>,&quot;tour&quot;:[</xsl:text>
    <xsl:for-each select="//main//a[starts-with(@href, '/concert/')]">
      <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
      <xsl:text>{&quot;href&quot;:</xsl:text><xsl:call-template name="str"><xsl:with-param name="val" select="@href"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'month'"/><xsl:with-param name="val" select="(.//time[p]/p)[1]"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'day'"/><xsl:with-param name="val" select="(.//time[p]/p)[2]"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'city'"/><xsl:with-param name="val" select="(.//h3)[1]"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'artist'"/><xsl:with-param name="val" select="(.//h3/following-sibling::p)[1]"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'when'"/><xsl:with-param name="val" select="(.//time[not(p)])[1]"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'venue'"/><xsl:with-param name="val" select="(.//time[not(p)]/following-sibling::span)[1]"/></xsl:call-template>
      <xsl:text>}</xsl:text>
    </xsl:for-each>

    <xsl:text>],&quot;discog&quot;:[</xsl:text>
    <xsl:for-each select="//main//section[@aria-label='Discography']//*[@data-encore-id='card']">
      <xsl:variable name="uri" select="substring-before(concat(substring-after(@aria-labelledby, 'card-title-'), '-'), '-')"/>
      <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
      <xsl:text>{&quot;kind&quot;:</xsl:text><xsl:call-template name="str"><xsl:with-param name="val" select="substring-before(substring-after($uri, 'spotify:'), ':')"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'href'"/><xsl:with-param name="val" select="concat('/', substring-before(substring-after($uri, 'spotify:'), ':'), '/', substring-after(substring-after($uri, 'spotify:'), ':'))"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'name'"/><xsl:with-param name="val" select="(.//*[@data-encore-id='cardTitle'])[1]"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'sub'"/><xsl:with-param name="val" select="(.//*[@data-encore-id='cardSubtitle'])[1]"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'art'"/><xsl:with-param name="val" select="(.//img/@src)[1]"/></xsl:call-template>
      <xsl:text>}</xsl:text>
    </xsl:for-each>

    <xsl:text>],&quot;popular&quot;:[</xsl:text>
    <xsl:for-each select="//main//*[@data-testid='tracklist-row']">
      <xsl:variable name="link" select="(.//a[contains(@href,'/track/')])[1]"/>
      <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
      <xsl:text>{&quot;name&quot;:</xsl:text><xsl:call-template name="str"><xsl:with-param name="val" select="$link"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'href'"/><xsl:with-param name="val" select="$link/@href"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'art'"/><xsl:with-param name="val" select="(.//img/@src)[1]"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'index'"/><xsl:with-param name="val" select="(.//div[@role='gridcell'][1]//span)[1]"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'plays'"/><xsl:with-param name="val" select="(.//div[@role='gridcell'][3]//*[@data-encore-id='text'])[1]"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'duration'"/><xsl:with-param name="val" select="(.//div[@role='gridcell'][last()]//*[@data-encore-id='text'])[1]"/></xsl:call-template>
      <xsl:call-template name="field"><xsl:with-param name="key" select="'play'"/><xsl:with-param name="val" select="(.//div[@role='gridcell'][1]//button/@aria-label)[1]"/></xsl:call-template>
      <xsl:text>}</xsl:text>
    </xsl:for-each>
    <xsl:text>]}</xsl:text>
  </xsl:template>
</xsl:stylesheet>
