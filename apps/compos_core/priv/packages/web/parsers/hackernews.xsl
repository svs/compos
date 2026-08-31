<?xml version="1.0" encoding="UTF-8"?>
<!-- Hacker News, calm: the stories and the comments, without the site.
     The whole-page reading gives the nav bar, the vote arrows, the hide
     and past links, and the login form. It also gives the separators HN
     draws between them, and pandoc escapes every one as a backslash pipe.

     A story is a title, the site it came from, and one line about it. A
     comment is who wrote it and what they said, at its depth in the
     thread. Nothing here needs a separator, so none is written. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" encoding="UTF-8" omit-xml-declaration="yes"/>

  <!-- how deep a reply is still drawn as a reply; past this the quote
       bars cost more width than the nesting is worth -->
  <xsl:variable name="max-depth" select="6"/>

  <xsl:template match="/">
    <html><body>
      <!-- an item page titles itself "Story | Hacker News", and that
           separator is the one thing this reading exists to remove -->
      <h1>
        <xsl:choose>
          <xsl:when test="contains(//title, ' | Hacker News')">
            <xsl:value-of select="substring-before(//title, ' | Hacker News')"/>
          </xsl:when>
          <xsl:otherwise><xsl:value-of select="//title"/></xsl:otherwise>
        </xsl:choose>
      </h1>
      <!-- an Ask HN or a text submission carries its own body above the
           thread -->
      <xsl:apply-templates select="//td[contains(@class, 'toptext')]"/>
      <xsl:variable name="stories"
                    select="//tr[contains(@class, 'athing')]
                              [not(contains(@class, 'comtr'))]"/>
      <xsl:if test="$stories">
        <ol start="{substring-before($stories[1]//span[@class='rank'], '.')}">
          <xsl:apply-templates select="$stories"/>
        </ol>
      </xsl:if>
      <xsl:apply-templates select="//tr[contains(@class, 'comtr')]"/>
      <!-- the next page of a listing, by itself -->
      <xsl:if test="//a[@class='morelink']">
        <p><a href="{//a[@class='morelink']/@href}">More</a></p>
      </xsl:if>
    </body></html>
  </xsl:template>

  <xsl:template match="td[contains(@class, 'toptext')]">
    <xsl:copy-of select="node()"/>
  </xsl:template>

  <!-- A story row and the row under it are one item: HN puts the title in
       the first and everything about it in the second. -->
  <xsl:template match="tr[contains(@class, 'athing')]">
    <xsl:variable name="sub"
                  select="following-sibling::tr[1]//td[contains(@class, 'subtext')]"/>
    <li>
      <a href="{.//span[@class='titleline']/a[1]/@href}">
        <xsl:copy-of select=".//span[@class='titleline']/a[1]/node()"/>
      </a>
      <xsl:if test=".//span[@class='sitestr']">
        <xsl:text> (</xsl:text>
        <xsl:value-of select=".//span[@class='sitestr']"/>
        <xsl:text>)</xsl:text>
      </xsl:if>
      <xsl:if test="$sub">
        <br/>
        <em>
          <xsl:value-of select="$sub//span[contains(@class, 'score')]"/>
          <xsl:if test="$sub//a[contains(@class, 'hnuser')]">
            <xsl:text> by </xsl:text>
            <xsl:value-of select="$sub//a[contains(@class, 'hnuser')]"/>
          </xsl:if>
          <xsl:if test="$sub//span[@class='age']/a">
            <xsl:text>, </xsl:text>
            <xsl:value-of select="$sub//span[@class='age']/a"/>
          </xsl:if>
          <!-- the comment count names itself; the age link points at the
               same item, so the href cannot tell them apart -->
          <xsl:variable name="comments"
                        select="$sub//a[contains(., 'comment') or contains(., 'discuss')]"/>
          <xsl:if test="$comments">
            <xsl:text>, </xsl:text>
            <a href="{$comments[1]/@href}">
              <xsl:value-of select="normalize-space($comments[1])"/>
            </a>
          </xsl:if>
        </em>
      </xsl:if>
    </li>
  </xsl:template>

  <!-- A comment keeps its place in the thread: HN states the depth as the
       indent cell, and a reply is drawn inside the comment it answers. -->
  <xsl:template match="tr[contains(@class, 'comtr')]">
    <xsl:variable name="depth">
      <xsl:choose>
        <xsl:when test=".//td[@class='ind']/@indent &gt; $max-depth">
          <xsl:value-of select="$max-depth"/>
        </xsl:when>
        <xsl:otherwise>
          <xsl:value-of select=".//td[@class='ind']/@indent"/>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="body">
      <p>
        <strong><xsl:value-of select=".//a[contains(@class, 'hnuser')]"/></strong>
        <xsl:if test=".//span[@class='age']/a">
          <xsl:text> </xsl:text>
          <em><xsl:value-of select=".//span[@class='age']/a"/></em>
        </xsl:if>
      </p>
      <xsl:copy-of select=".//div[contains(@class, 'commtext')]/node()"/>
    </xsl:variable>
    <xsl:call-template name="reply">
      <xsl:with-param name="depth" select="$depth"/>
      <xsl:with-param name="body" select="$body"/>
    </xsl:call-template>
  </xsl:template>

  <!-- One blockquote per level of reply. XSLT builds the nesting by
       recursion: there is no loop that can wrap what it has already
       written. -->
  <xsl:template name="reply">
    <xsl:param name="depth"/>
    <xsl:param name="body"/>
    <xsl:choose>
      <xsl:when test="$depth &gt; 0">
        <blockquote>
          <xsl:call-template name="reply">
            <xsl:with-param name="depth" select="$depth - 1"/>
            <xsl:with-param name="body" select="$body"/>
          </xsl:call-template>
        </blockquote>
      </xsl:when>
      <xsl:otherwise><xsl:copy-of select="$body"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>
</xsl:stylesheet>
