;;; substack-test.scm --- tests for the Substack app.

(domain! 'testing)
(effects! '(write))

(deftest 'substack-subscriptions-include-author-and-exclude-owned-publications
  "the index keeps author metadata and never lists the user's publication"
  (lambda ()
    (let* ((payload
             (list 'publications
                   (list (list 'id 1 'name "Alpha" 'author_name "Ada"
                               'subdomain "alpha")
                         (list 'id 2 'name "Mine" 'author_name "Me"
                               'custom_domain "mine.example"))
                   'subscriptions
                   (list (list 'publication_id 1 'membership_state "free"))
                   'publicationUsers
                   (list (list 'publication_id 2))))
           (rows (substack-parse-subscriptions payload))
           (row (car rows)))
      (check-equal! (length rows) 1 "owned publication is excluded")
      (check-equal! (plist-get row 'author) "Ada" "author is retained")
      (check-equal! (plist-get row 'url) "https://alpha.substack.com"
                    "subdomain becomes a canonical URL"))))

(deftest 'substack-has-consolidated-list-detail-reader-modes
  "the app registers its listing and publication list"
  (lambda ()
    (check-true! (pair? (list-mode-opts "substack-mode")) "listing is a list mode")
    (check-true! (pair? (list-mode-opts "substack-detail-mode")) "publication is a list mode")))

(deftest 'substack-uses-one-stable-buffer-per-publication-and-post
  "detail and reader names consolidate repeat visits"
  (lambda ()
    (let ((publication (list 'id 7 'name "Latent Space"))
          (post (list 'id 9 'title "Harnesses")))
      (check-equal! (substack--detail-buffer publication)
                    (substack--detail-buffer publication)
                    "publication buffer is stable")
      (check-equal! (substack--reader-buffer post)
                    (substack--reader-buffer post)
                    "reader buffer is stable"))))
