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

  <!-- A reply sits under the comment it answers, as a list inside that
       comment. Three levels of that already take a quarter of the width,
       so a deeper reply is drawn at the third level, under the reply it
       descends from, in thread order. A key per depth names the parent:
       XSLT 1.0 allows no variable in a match pattern, so the three is
       written into each. -->
  <xsl:key name="replies"
           match="tr[contains(@class, 'comtr')][.//td[@class='ind']/@indent = 1]"
           use="generate-id(preceding-sibling::tr[contains(@class, 'comtr')]
                             [.//td[@class='ind']/@indent &lt; 1][1])"/>
  <xsl:key name="replies"
           match="tr[contains(@class, 'comtr')][.//td[@class='ind']/@indent = 2]"
           use="generate-id(preceding-sibling::tr[contains(@class, 'comtr')]
                             [.//td[@class='ind']/@indent &lt; 2][1])"/>
  <xsl:key name="replies"
           match="tr[contains(@class, 'comtr')][.//td[@class='ind']/@indent &gt;= 3]"
           use="generate-id(preceding-sibling::tr[contains(@class, 'comtr')]
                             [.//td[@class='ind']/@indent &lt; 3][1])"/>

  <xsl:template match="/">
    <xsl:variable name="stories"
                  select="//tr[contains(@class, 'athing')]
                            [not(contains(@class, 'comtr'))]"/>
    <!-- an item page is one story and its thread: the story is the title,
         not a list of one -->
    <xsl:variable name="item"
                  select="$stories[1][ancestor::table[contains(@class, 'fatitem')]]
                                     [.//span[@class='titleline']]"/>
    <html><body>
      <xsl:choose>
        <xsl:when test="$item">
          <h1>
            <a>
              <xsl:attribute name="href">
                <xsl:call-template name="story-href">
                  <xsl:with-param name="story" select="$item"/>
                </xsl:call-template>
              </xsl:attribute>
              <xsl:copy-of select="$item//span[@class='titleline']/a[1]/node()"/>
            </a>
          </h1>
          <p>
            <em>
              <xsl:if test="$item//span[@class='sitestr']">
                <xsl:value-of select="$item//span[@class='sitestr']"/>
                <xsl:text> · </xsl:text>
              </xsl:if>
              <xsl:call-template name="about">
                <xsl:with-param name="story" select="$item"/>
              </xsl:call-template>
            </em>
          </p>
        </xsl:when>
        <!-- a page titles itself "Story | Hacker News", and that
             separator is the one thing this reading exists to remove -->
        <xsl:otherwise>
          <h1>
            <xsl:choose>
              <xsl:when test="contains(//title, ' | Hacker News')">
                <xsl:value-of select="substring-before(//title, ' | Hacker News')"/>
              </xsl:when>
              <xsl:otherwise><xsl:value-of select="//title"/></xsl:otherwise>
            </xsl:choose>
          </h1>
        </xsl:otherwise>
      </xsl:choose>
      <!-- an Ask HN or a text submission carries its own body above the
           thread -->
      <xsl:apply-templates select="//td[contains(@class, 'toptext')]"/>
      <xsl:if test="$stories and not($item)">
        <ol start="{substring-before($stories[1]//span[@class='rank'], '.')}">
          <xsl:apply-templates select="$stories"/>
        </ol>
      </xsl:if>
      <xsl:variable name="top"
                    select="//tr[contains(@class, 'comtr')]
                              [.//td[@class='ind']/@indent = 0]"/>
      <xsl:if test="$top">
        <ul><xsl:apply-templates select="$top"/></ul>
      </xsl:if>
      <!-- the next page of a listing, by itself -->
      <xsl:if test="//a[@class='morelink']">
        <p><a href="{concat('https://news.ycombinator.com/', //a[@class='morelink']/@href)}">More</a></p>
      </xsl:if>
    </body></html>
  </xsl:template>

  <xsl:template match="td[contains(@class, 'toptext')]">
    <xsl:copy-of select="node()"/>
  </xsl:template>

  <!-- A story row and the row under it are one item: HN puts the title in
       the first and everything about it in the second. -->
  <xsl:template match="tr[contains(@class, 'athing')]">
    <li>
      <a>
        <xsl:attribute name="href">
          <xsl:call-template name="story-href">
            <xsl:with-param name="story" select="."/>
          </xsl:call-template>
        </xsl:attribute>
        <xsl:copy-of select=".//span[@class='titleline']/a[1]/node()"/>
      </a>
      <xsl:if test=".//span[@class='sitestr']">
        <xsl:text> (</xsl:text>
        <xsl:value-of select=".//span[@class='sitestr']"/>
        <xsl:text>)</xsl:text>
      </xsl:if>
      <xsl:if test="following-sibling::tr[1]//td[contains(@class, 'subtext')]">
        <br/>
        <em>
          <xsl:call-template name="about">
            <xsl:with-param name="story" select="."/>
          </xsl:call-template>
        </em>
      </xsl:if>
    </li>
  </xsl:template>

  <!-- where a story title goes: its own link, or an HN path for Ask HN -->
  <xsl:template name="story-href">
    <xsl:param name="story"/>
    <xsl:variable name="href" select="$story//span[@class='titleline']/a[1]/@href"/>
    <xsl:choose>
      <xsl:when test="starts-with($href, 'http://') or starts-with($href, 'https://')">
        <xsl:value-of select="$href"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="concat('https://news.ycombinator.com/', $href)"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- the points, the poster, the age and the comment count -->
  <xsl:template name="about">
    <xsl:param name="story"/>
    <xsl:variable name="sub"
                  select="$story/following-sibling::tr[1]//td[contains(@class, 'subtext')]"/>
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
      <a href="{concat('https://news.ycombinator.com/', $comments[1]/@href)}">
        <xsl:value-of select="normalize-space($comments[1])"/>
      </a>
    </xsl:if>
  </xsl:template>

  <!-- A comment is who wrote it, then what they said: the byline and the
       first paragraph share one block, so the name reads as the start of
       the comment and not as a heading over it. -->
  <xsl:template match="tr[contains(@class, 'comtr')]">
    <xsl:variable name="text" select=".//div[contains(@class, 'commtext')]"/>
    <xsl:variable name="replies" select="key('replies', generate-id())"/>
    <li>
      <p>
        <strong><xsl:value-of select=".//a[contains(@class, 'hnuser')]"/></strong>
        <xsl:if test=".//span[@class='age']/a">
          <xsl:text> · </xsl:text>
          <em><xsl:value-of select=".//span[@class='age']/a"/></em>
        </xsl:if>
        <br/>
        <xsl:copy-of select="$text/node()[not(self::p or self::pre)]
                                         [not(preceding-sibling::p or preceding-sibling::pre)]"/>
      </p>
      <xsl:copy-of select="$text/node()[self::p or self::pre
                                         or preceding-sibling::p or preceding-sibling::pre]"/>
      <xsl:if test="$replies">
        <ul><xsl:apply-templates select="$replies"/></ul>
      </xsl:if>
    </li>
  </xsl:template>
</xsl:stylesheet>
