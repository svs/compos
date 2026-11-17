;;; mcp-test.scm --- what the catalog says of the MCP calls.

(domain! 'testing)
(effects! '(write))

(deftest 'mcp-call-is-stamped-as-reaching-outside
  "a tool of any server can fetch a URL or post a message, so mcp-call! is external, not a local write"
  (lambda ()
    (let ((fx (plist-get (catalog-entry 'function "mcp-call!") 'effects)))
      (check-true! (and (member "external" fx) #t) "external")
      (check-true! (and (member "write" fx) #t) "and a write"))))
