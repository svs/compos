;;; kimi.scm --- Kimi Code CLI as an ACP connector.
;;;
;;; Moonshot's kimi-code speaks ACP behind `kimi acp`. The device-code
;;; sign-in through `kimi login` stores the account in ~/.kimi-code; the
;;; session reports its models as ACP config options.

(domain! 'chat)
(effects! '(write))

(define-connector! "kimi"
  '(cmd "kimi acp"
    description "Kimi Code CLI — Moonshot account"
    model-config #t
    ;; our prompt sections ride the first turn; _meta is not known to reach it
    system-in-prompt #t
    install (("kimi" "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash"))
    signin "kimi login"
    accepts "^(kimi|moonshot)"))

(provide 'connector-kimi)
