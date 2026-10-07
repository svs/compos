<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:import href="common.xsl"/>

  <xsl:template match="/">
    <html><body>
      <xsl:apply-templates select="//main//section[contains(@class,'biographical')]/article" mode="copy"/>
    </body></html>
  </xsl:template>

  <!-- mobile page navigation -->
  <xsl:template match="select" mode="copy"/>

  <!-- language links -->
  <xsl:template match="p[contains(@class,'smalltext')]" mode="copy"/>

  <!-- citation box -->
  <xsl:template match="footer[contains(@class,'pagecite')]" mode="copy"/>

  <!-- back to top link -->
  <xsl:template match="div[contains(@class,'back-to-top')]" mode="copy"/>
</xsl:stylesheet>
