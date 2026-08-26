<?xml version="1.0" encoding="UTF-8"?>
<!-- A search results page, calm: the results and nothing else.
     The whole-page reading keeps the region list, the time filters and
     one redirect wrapper per result. A result is a title, the site it
     is on, and a snippet. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" encoding="UTF-8" omit-xml-declaration="yes"/>
  <!-- No strip-space here. The engine wraps each matched word in <b>,
       and the single spaces between those tags are whitespace-only text
       nodes: stripping them joins the words ("EmacsLisp"). -->

  <xsl:template match="/">
    <html><body>
      <xsl:apply-templates select="//div[contains(@class, 'result__body')]"/>
    </body></html>
  </xsl:template>

  <!-- copy-of, not value-of: the engine marks the matched words with
       <b>, and value-of would drop the tags and run the words together
       ("GNU EmacsLisp Reference Manual"). -->
  <xsl:template match="div[contains(@class, 'result__body')]">
    <h2>
      <a href="{.//a[contains(@class, 'result__a')]/@href}">
        <xsl:copy-of select=".//a[contains(@class, 'result__a')]/node()"/>
      </a>
    </h2>
    <p><xsl:value-of select=".//a[contains(@class, 'result__url')]"/></p>
    <p><xsl:copy-of select=".//a[contains(@class, 'result__snippet')]/node()"/></p>
  </xsl:template>
</xsl:stylesheet>
