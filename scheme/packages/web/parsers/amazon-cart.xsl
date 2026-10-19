<?xml version="1.0" encoding="UTF-8"?>
<!-- The Amazon cart as records.

     Only the ACTIVE lines. A cart page carries two lists: id="sc-active-*"
     is what you are buying, id="sc-saved-*" is saved for later, and on one
     real cart there were 3 active against 37 saved. Anything that searches
     the page as a whole calls all forty of them "in the cart". -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="text" encoding="UTF-8" omit-xml-declaration="yes"/>
  <xsl:strip-space elements="*"/>

  <xsl:template name="esc-bs">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="contains($s, '\')">
        <xsl:value-of select="substring-before($s, '\')"/>
        <xsl:text>\\</xsl:text>
        <xsl:call-template name="esc-bs">
          <xsl:with-param name="s" select="substring-after($s, '\')"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$s"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="esc">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="contains($s, '&quot;')">
        <xsl:call-template name="esc-bs">
          <xsl:with-param name="s" select="substring-before($s, '&quot;')"/>
        </xsl:call-template>
        <xsl:text>\&quot;</xsl:text>
        <xsl:call-template name="esc">
          <xsl:with-param name="s" select="substring-after($s, '&quot;')"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <xsl:call-template name="esc-bs">
          <xsl:with-param name="s" select="$s"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="field">
    <xsl:param name="key"/>
    <xsl:param name="val"/>
    <xsl:text>&quot;</xsl:text>
    <xsl:value-of select="$key"/>
    <xsl:text>&quot;:&quot;</xsl:text>
    <xsl:call-template name="esc">
      <xsl:with-param name="s" select="normalize-space($val)"/>
    </xsl:call-template>
    <xsl:text>&quot;</xsl:text>
  </xsl:template>

  <xsl:template match="/">
    <xsl:text>[</xsl:text>
    <!-- A removal notice keeps its asin and its sc-active- id but holds no
         product: no quantity field, no price. A thing in a cart has a count. -->
    <xsl:for-each select="//div[starts-with(@id, 'sc-active-')][string-length(@data-asin) &gt; 0][.//input[contains(@class,'sc-quantity-textfield')]]">
      <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
      <xsl:text>{</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'asin'"/>
        <xsl:with-param name="val" select="@data-asin"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:choose>
        <xsl:when test=".//span[contains(@class,'a-truncate-full')]">
          <xsl:call-template name="field">
            <xsl:with-param name="key" select="'title'"/>
            <xsl:with-param name="val" select=".//span[contains(@class,'a-truncate-full')][1]"/>
          </xsl:call-template>
        </xsl:when>
        <xsl:otherwise>
          <xsl:call-template name="field">
            <xsl:with-param name="key" select="'title'"/>
            <xsl:with-param name="val" select=".//span[contains(@class,'sc-product-title')][1]"/>
          </xsl:call-template>
        </xsl:otherwise>
      </xsl:choose>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'price'"/>
        <xsl:with-param name="val" select=".//span[contains(@class,'apex-price-to-pay-value')][1]//span[contains(@class,'a-price-whole')][1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'mrp'"/>
        <xsl:with-param name="val" select=".//span[contains(@class,'apex-basis-price-value')][1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'qty'"/>
        <xsl:with-param name="val" select=".//input[contains(@class,'sc-quantity-textfield')][1]/@value"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'image'"/>
        <xsl:with-param name="val" select="(.//img[contains(@class,'sc-product-image')] | .//img[not(contains(@src,'loadIndicators'))])[1]/@src"/>
      </xsl:call-template>
      <xsl:text>}</xsl:text>
    </xsl:for-each>
    <xsl:text>]</xsl:text>
  </xsl:template>
</xsl:stylesheet>