<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" encoding="UTF-8" omit-xml-declaration="yes"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/">
    <html>
      <body>
        <xsl:apply-templates
          select="//*[@role='article' and (@aria-label='Note' or @aria-label='Post')]"
          mode="article"/>
      </body>
    </html>
  </xsl:template>

  <xsl:template match="*" mode="article">
    <xsl:variable name="avatar" select=".//img[contains(
      translate(@alt, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'),
      'avatar'
    )][1]"/>
    <xsl:variable name="author" select=".//a[
      starts-with(@href, '/@') and
      not(contains(@href, '/note/')) and
      normalize-space(.) != ''
    ][1]"/>
    <xsl:variable name="date" select=".//a[
      contains(@href, '/note/') and
      normalize-space(.) != ''
    ][1]"/>

    <xsl:copy>
      <xsl:copy-of select="@*"/>
      <div class="compos-substack-header">
        <xsl:if test="$avatar">
          <img src="{concat($avatar/@src, '#compos-avatar')}" alt=""/>
          <xsl:text> </xsl:text>
        </xsl:if>
        <xsl:if test="$author">
          <a href="{$author/@href}">
            <xsl:value-of select="normalize-space($author)"/>
          </a>
        </xsl:if>
        <xsl:if test="$date">
          <xsl:text> · </xsl:text>
          <a href="{$date/@href}">
            <xsl:value-of select="normalize-space($date)"/>
          </a>
        </xsl:if>
        <xsl:for-each select=".//button[
          (@aria-label='Like' or @aria-label='Comment' or @aria-label='Restack')
          and normalize-space(.) != ''
        ]">
          <xsl:text> </xsl:text>
          <xsl:choose>
            <xsl:when test="@aria-label='Like'"><xsl:text>♥ </xsl:text></xsl:when>
            <xsl:when test="@aria-label='Comment'"><xsl:text>💬 </xsl:text></xsl:when>
            <xsl:otherwise><xsl:text>↻ </xsl:text></xsl:otherwise>
          </xsl:choose>
          <xsl:value-of select="normalize-space(.)"/>
        </xsl:for-each>
      </div>
      <xsl:apply-templates select="node()" mode="copy">
        <xsl:with-param name="avatar-src" select="$avatar/@src"/>
        <xsl:with-param name="author-href" select="$author/@href"/>
        <xsl:with-param name="author-text" select="normalize-space($author)"/>
        <xsl:with-param name="date-href" select="$date/@href"/>
        <xsl:with-param name="date-text" select="normalize-space($date)"/>
      </xsl:apply-templates>
    </xsl:copy>
    <xsl:if test="position() != last()">
      <div class="compos-article-separator">COMPOS-ARTICLE-SEPARATOR</div>
    </xsl:if>
  </xsl:template>

  <xsl:template match="@*|node()" mode="copy">
    <xsl:param name="avatar-src"/>
    <xsl:param name="author-href"/>
    <xsl:param name="author-text"/>
    <xsl:param name="date-href"/>
    <xsl:param name="date-text"/>
    <xsl:copy>
      <xsl:apply-templates select="@*|node()" mode="copy">
        <xsl:with-param name="avatar-src" select="$avatar-src"/>
        <xsl:with-param name="author-href" select="$author-href"/>
        <xsl:with-param name="author-text" select="$author-text"/>
        <xsl:with-param name="date-href" select="$date-href"/>
        <xsl:with-param name="date-text" select="$date-text"/>
      </xsl:apply-templates>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="a[contains(@href, '/p/')]" mode="copy">
    <xsl:param name="avatar-src"/>
    <xsl:variable name="card-title"
      select="(.//*[not(*) and normalize-space(.) != '' and not(ancestor::button)])[last()]"/>
    <xsl:apply-templates select=".//img[1]" mode="copy">
      <xsl:with-param name="avatar-src" select="$avatar-src"/>
    </xsl:apply-templates>
    <xsl:if test="$card-title">
      <div class="compos-substack-article-link">
        <a href="{@href}">
          <xsl:value-of select="normalize-space($card-title)"/>
        </a>
      </div>
    </xsl:if>
  </xsl:template>

  <xsl:template match="a" mode="copy">
    <xsl:param name="avatar-src"/>
    <xsl:param name="author-href"/>
    <xsl:param name="author-text"/>
    <xsl:param name="date-href"/>
    <xsl:param name="date-text"/>
    <xsl:if test="not(
      (@href=$author-href and
        (normalize-space(.)=$author-text or normalize-space(.)='')) or
      (@href=$date-href and normalize-space(.)=$date-text)
    )">
      <xsl:copy>
        <xsl:apply-templates select="@*|node()" mode="copy">
          <xsl:with-param name="avatar-src" select="$avatar-src"/>
          <xsl:with-param name="author-href" select="$author-href"/>
          <xsl:with-param name="author-text" select="$author-text"/>
          <xsl:with-param name="date-href" select="$date-href"/>
          <xsl:with-param name="date-text" select="$date-text"/>
        </xsl:apply-templates>
      </xsl:copy>
    </xsl:if>
  </xsl:template>

  <xsl:template
    match="img[
      @sizes='20px' or
      contains(@style, 'width: 20px') or
      contains(@src, 'w_20,h_20')
    ]"
    mode="copy">
    <xsl:param name="avatar-src"/>
    <xsl:if test="not(@src=$avatar-src)">
      <div class="compos-substack-publication">
        <img src="{concat(@src, '#compos-avatar')}" alt=""/>
        <xsl:text> </xsl:text>
        <span class="compos-substack-publication-name">
          <xsl:value-of select="normalize-space(@alt)"/>
        </span>
      </div>
    </xsl:if>
  </xsl:template>

  <xsl:template match="img" mode="copy">
    <xsl:param name="avatar-src"/>
    <xsl:if test="not(@src=$avatar-src)">
      <xsl:copy>
        <xsl:apply-templates select="@*|node()" mode="copy"/>
      </xsl:copy>
    </xsl:if>
  </xsl:template>

  <xsl:template
    match="button[
      @aria-label='Like' or
      @aria-label='Comment' or
      @aria-label='Restack' or
      @aria-label='Share'
    ]"
    mode="copy"/>
</xsl:stylesheet>
