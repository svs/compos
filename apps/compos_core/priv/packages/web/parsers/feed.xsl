<?xml version="1.0" encoding="UTF-8"?>
<!-- An RSS 2.0, RSS 1.0, or Atom feed becomes one line per item:
     FEED-TITLE <tab> DATE <tab> LINK <tab> ITEM-TITLE
     local-name() matching keeps one template across the namespaces. -->
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="text" encoding="UTF-8"/>

  <xsl:variable name="feed-title"
    select="normalize-space((//*[local-name()='channel']/*[local-name()='title']
           | /*[local-name()='feed']/*[local-name()='title'])[1])"/>

  <xsl:template match="/">
    <xsl:for-each select="//*[local-name()='item' or local-name()='entry']">
      <xsl:value-of select="$feed-title"/>
      <xsl:text>&#9;</xsl:text>
      <xsl:value-of select="normalize-space((*[local-name()='pubDate']
        | *[local-name()='published'] | *[local-name()='updated']
        | *[local-name()='date'])[1])"/>
      <xsl:text>&#9;</xsl:text>
      <xsl:choose>
        <!-- RSS: the link is element text. Atom: it is an href attribute,
             and rel="alternate" names the article among the rel links. -->
        <xsl:when test="normalize-space(*[local-name()='link' and not(@href)][1]) != ''">
          <xsl:value-of select="normalize-space(*[local-name()='link' and not(@href)][1])"/>
        </xsl:when>
        <xsl:when test="*[local-name()='link'][@rel='alternate']/@href">
          <xsl:value-of select="*[local-name()='link'][@rel='alternate'][1]/@href"/>
        </xsl:when>
        <xsl:otherwise>
          <xsl:value-of select="*[local-name()='link'][1]/@href"/>
        </xsl:otherwise>
      </xsl:choose>
      <xsl:text>&#9;</xsl:text>
      <xsl:value-of select="normalize-space(*[local-name()='title'][1])"/>
      <xsl:text>&#10;</xsl:text>
    </xsl:for-each>
  </xsl:template>
</xsl:stylesheet>
