<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" encoding="UTF-8" omit-xml-declaration="yes"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/">
    <html><body>
      <xsl:apply-templates select="//main" mode="copy"/>
    </body></html>
  </xsl:template>

  <xsl:template match="@*|node()" mode="copy">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()" mode="copy"/>
    </xsl:copy>
  </xsl:template>

  <!-- Keep content images, but remove branding, avatars, tool logos, icons, and decorative SVGs. -->
  <xsl:template match="img[contains(@src, 'tool_icons/') or contains(@src, '/me.png') or contains(@src, '/favicon') or contains(@alt, 'logo') or contains(@alt, 'Logo')]" mode="copy"/>
  <xsl:template match="svg" mode="copy"/>
  <xsl:template match="script|style|noscript" mode="copy"/>
  <xsl:template match="div[contains(@class, 'fixed') or contains(@class, 'loader') or contains(@class, 'dock')]" mode="copy"/>
</xsl:stylesheet>
