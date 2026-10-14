<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="text" encoding="UTF-8" omit-xml-declaration="yes"/>
  <!-- The search's categories as site-app status tabs. A category page draws
       no chips of its own, so they are fixed; the query is the path segment
       after the search, and the section's filter marks the one showing. -->
  <xsl:template match="/">
    <xsl:text>[{"label":"Songs","query":"tracks","count":""},{"label":"Albums","query":"albums","count":""},{"label":"Artists","query":"artists","count":""},{"label":"Playlists","query":"playlists","count":""}]</xsl:text>
  </xsl:template>
</xsl:stylesheet>
