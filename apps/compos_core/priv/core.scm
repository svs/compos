;;; core.scm --- the libraries every package may use without a require.
;;;
;;; The kernel is editor.scm and themes.scm. This file adds the forms that
;;; almost every package calls at load: defcustom and defgroup, and advice.
;;; Emacs preloads the same two libraries.
;;;
;;; A package that needs any other library at load says (require 'NAME) at
;;; its top. The load order check boots this file and one package, so a
;;; missing require fails there and not at boot.

(require 'custom)
(require 'advice)
