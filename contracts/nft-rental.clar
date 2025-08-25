;; ------------------------------------------------------------
;; NFT Rent & Lease Protocol (Stacks / Clarity v2)
;; ------------------------------------------------------------
;; Model:
;; - Owner escrows NFT (SIP-009) in this contract and sets a daily price.
;; - Renter pays STX to rent for N days; contract records active rental.
;; - NFT stays in escrow (safe and reclaimable). Integrations can check
;;   `is-active-renter` to gate features while rented.
;; - Owner can withdraw accumulated earnings in STX anytime.
;; - Supports extensions and delisting (when not rented).
;; ------------------------------------------------------------

;; ---------- SIP-009 trait (minimal) ----------
(define-trait sip009-nft-standard
  (
    (transfer (uint principal principal) (response bool uint))
    (get-owner (uint) (response principal uint))
    (get-total-supply () (response uint uint))
  )
)

;; ---------- Errors ----------
(define-constant ERR-NOT-FOUND       (err u404))
(define-constant ERR-UNAUTHORIZED    (err u401))
(define-constant ERR-BAD-ARGS        (err u400))
(define-constant ERR-ACTIVE-RENTAL   (err u409))
(define-constant ERR-NOT-ACTIVE      (err u410))
(define-constant ERR-INSUFFICIENT    (err u402))
(define-constant ERR-TOO-EARLY       (err u425))
(define-constant ERR-TOO-LATE        (err u426))

;; ---------- Helpers ----------
(define-read-only (now) burn-block-height)
(define-read-only (days-to-blocks (days uint)) (* days u144)) ;; ~10 min/block => ~144 blocks/day

(define-read-only (mul (a uint) (b uint)) (* a b))

;; ---------- Storage ----------
(define-data-var next-listing-id uint u1)

;; Each listing holds one escrowed NFT.
(define-map listings
  { id: uint }
  {
    owner: principal,
    nft: principal,       ;; contract principal of the NFT
    token-id: uint,
    daily-price: uint,    ;; STX per day
    max-days: uint,
    active: bool          ;; true if NFT is currently listed/escrowed
  })

;; Tracks an active rental per listing (0 or 1 at a time).
(define-map rentals
  { id: uint }
  {
    renter: principal,
    start-height: uint,
    end-height: uint,
    paid: uint            ;; total STX paid for current rental (for views)
  })

;; Owner earnings (claimable STX).
(define-map earnings
  { who: principal }
  { amount: uint })

;; Return listing details if it matches the target NFT
(define-read-only (find-listing (id uint) (target-nft principal) (target-token-id uint))
  (match (map-get? listings {id: id})
    listing (and (is-eq (get nft listing) target-nft)
                 (is-eq (get token-id listing) target-token-id)
                 (get active listing))
    false))

;; ---------- Views ----------
;; Read-only functions to query state
(define-read-only (get-listing (id uint))
  (match (map-get? listings { id: id })
    item (some item)
    none))

(define-read-only (get-rental (id uint))
  (map-get? rentals { id: id }))

(define-read-only (get-earnings (who principal))
  (default-to u0 (get amount (map-get? earnings { who: who }))))

;; Core gate: does `who` currently have usage rights?
(define-read-only (is-active-renter (nft principal) (token-id uint) (who principal))
  (let ((id (var-get next-listing-id)))
    (if (and (> id u0)
             (find-listing (- id u1) nft token-id))
      (match (get-rental (- id u1))
        rental (and (is-eq who (get renter rental))
                   (>= (now) (get start-height rental))
                   (<  (now) (get end-height rental)))
        false)
      false)))

;; ---------- Internal helpers ----------
(define-private (credit-earnings (who principal) (amt uint))
  (let ((prev (get-earnings who)))
    (if (>= (+ prev amt) prev)  ;; check for overflow
      (begin
        (map-set earnings { who: who } { amount: (+ prev amt) })
        (ok amt))  ;; Return credited amount on success
      ERR-BAD-ARGS)))

(define-private (has-active-rental? (id uint))
  (match (map-get? rentals {id: id})
    rental (and (> (get end-height rental) (now))  ;; not expired
               (>= (now) (get start-height rental)))
    false))

(define-private (clear-rental (id uint))
  (begin
    (map-delete rentals { id: id })
    (ok true)))

;; ---------- Create and Remove Listings ----------
;; Create a new NFT listing
(define-public (create-listing
  (nft <sip009-nft-standard>) (nft-principal principal)
  (token-id uint) (daily-price uint) (max-days uint))
  (let 
    ((input-valid (and (> daily-price u0) (> max-days u0))))
    
    ;; Validate inputs
    (asserts! input-valid ERR-BAD-ARGS)

    ;; Verify ownership
    (let ((owner-resp (try! (contract-call? nft get-owner token-id))))
      (asserts! (is-eq owner-resp tx-sender) ERR-UNAUTHORIZED)

      ;; Transfer NFT to escrow
      (try! (contract-call? nft transfer token-id tx-sender (as-contract tx-sender)))

      ;; Create listing
      (let ((id (var-get next-listing-id))
            (new-listing {
              owner: tx-sender,
              nft: nft-principal,
              token-id: token-id,
              daily-price: daily-price,
              max-days: max-days,
              active: true
            }))
        (map-set listings {id: id} new-listing)
        (var-set next-listing-id (+ id u1))
        (ok id)))))

(define-public (delist (nft <sip009-nft-standard>) (id uint))
  (begin
    (asserts! (is-some (map-get? listings {id: id})) ERR-NOT-FOUND)
    (let ((listing (unwrap! (map-get? listings {id: id}) ERR-NOT-FOUND)))
      (begin
        (asserts! (is-eq (get owner listing) tx-sender) ERR-UNAUTHORIZED)
        (asserts! (get active listing) ERR-NOT-ACTIVE)
        (asserts! (not (has-active-rental? id)) ERR-ACTIVE-RENTAL)
        
        ;; transfer NFT back to owner
        (try! (contract-call? nft transfer 
                             (get token-id listing) 
                             (as-contract tx-sender) 
                             (get owner listing)))
        
        ;; mark inactive
        (map-set listings {id: id} (merge listing {active: false}))
        (ok true)))))

;; ---------- Rent / Extend / End ----------
(define-public (rent (id uint) (days uint))
  (begin
    (let ((listing (unwrap! (map-get? listings {id: id}) ERR-NOT-FOUND)))
      (asserts! (get active listing) ERR-NOT-ACTIVE)
      (asserts! (not (has-active-rental? id)) ERR-ACTIVE-RENTAL)
      (asserts! (and (> days u0) (<= days (get max-days listing))) ERR-BAD-ARGS))

    ;; At this point all checks have passed
    (let ((listing (unwrap-panic (map-get? listings {id: id})))  ;; Safe since we just checked
          (price (* (get daily-price listing) days))
          (recipient (as-contract tx-sender))
          (start (now))
          (end (+ (now) (days-to-blocks days))))
      ;; collect STX and record rental
      (asserts! (is-ok (stx-transfer? price tx-sender recipient)) ERR-INSUFFICIENT)
      (map-set rentals {id: id}
        {renter: tx-sender, start-height: start, end-height: end, paid: price})
      ;; return success response
      (ok {start: start, end: end, paid: price}))))

(define-public (extend (id uint) (extra-days uint))
  (let ((listing (try! (safe-get-listing id)))
        (rental (try! (safe-get-rental id)))
        (current-blocks (- (get end-height rental) (get start-height rental)))
        (extra-blocks (days-to-blocks extra-days))
        (total-days (/ (+ current-blocks extra-blocks) (days-to-blocks u1)))
        (extra-price (* (get daily-price listing) extra-days))
        (new-end (+ (get end-height rental) extra-blocks)))
    ;; Validate state
    (try! (begin
      (if (and (get active listing)
               (is-eq (get renter rental) tx-sender)
               (> extra-days u0)
               (<= total-days (get max-days listing)))
        (ok true)
        ERR-BAD-ARGS)))

    ;; Handle payment
    (try! (stx-transfer? extra-price tx-sender (as-contract tx-sender)))
    
    ;; Update rental atomically
    (map-set rentals {id: id}
      {
        renter: (get renter rental),
        start-height: (get start-height rental),
        end-height: new-end,
        paid: (+ (get paid rental) extra-price)
      })
      
    ;; Credit owner earnings and return
    (try! (credit-earnings (get owner listing) extra-price))
    (ok {new-end: new-end, extra-paid: extra-price})))

;; Anyone can finalize an expired rental record (housekeeping).
(define-public (end-rental (id uint))
  (begin
    (try! (validate-map-id id))
    (let ((rental (try! (safe-get-rental id))))
      ;; Validate rental can be ended
      (if (and (> (get end-height rental) u0)
               (>= (now) (get end-height rental)))
        (begin
          (map-delete rentals {id: id})
          (ok true))
        ERR-TOO-EARLY))))

;; ---------- Earnings ----------
(define-public (withdraw-earnings)
  (let ((amt (get-earnings tx-sender)))
    (begin
      (asserts! (> amt u0) ERR-INSUFFICIENT)
      ;; Clear earnings first (to prevent re-entrancy)
      (map-set earnings { who: tx-sender } { amount: u0 })
      ;; Transfer STX - if it fails we still return ERR-INSUFFICIENT
      (try! (stx-transfer? amt (as-contract tx-sender) tx-sender))
      ;; Return success
      (ok true))))

;; ---------- Admin (optional re-escrow recovery) ----------
;; If the NFT somehow isn't owned by the contract anymore,
;; owner can mark listing inactive to prevent new rentals.
(define-public (deactivate (id uint))
  (match (map-get? listings {id: id})
    listing 
      (begin
        (asserts! (is-eq (get owner listing) tx-sender) ERR-UNAUTHORIZED)
        (map-set listings {id: id} (merge listing {active: false}))
        (ok true))
    ERR-NOT-FOUND))

;; Validate rental extension parameters
(define-private (validate-extension (listing {owner: principal, nft: principal, token-id: uint, daily-price: uint, max-days: uint, active: bool})
                                  (rental {renter: principal, start-height: uint, end-height: uint, paid: uint})
                                  (extra-days uint))
  (begin
    (asserts! (get active listing) ERR-NOT-ACTIVE)
    (asserts! (> extra-days u0) ERR-BAD-ARGS)
    (asserts! (is-eq (get renter rental) tx-sender) ERR-UNAUTHORIZED)

    ;; Check duration limits
    (let ((current-blocks (- (get end-height rental) (get start-height rental)))
          (extra-blocks (days-to-blocks extra-days))
          (total-days (/ (+ current-blocks extra-blocks) (days-to-blocks u1))))
      (if (<= total-days (get max-days listing))
        (ok true)
        ERR-BAD-ARGS))))


;; ---------- Data validation ----------
;; Basic validation helpers
(define-private (validate-uint-positive (n uint))
  (> n u0))

(define-private (validate-listing (listing {owner: principal, nft: principal, token-id: uint, daily-price: uint, max-days: uint, active: bool}))
  (begin 
    (asserts! (and (validate-uint-positive (get daily-price listing))
                   (validate-uint-positive (get max-days listing)))
              ERR-BAD-ARGS)
    (ok true)))

(define-private (validate-rental (rental {renter: principal, start-height: uint, end-height: uint, paid: uint}))
  (begin
    (asserts! (and (> (get end-height rental) (get start-height rental))
                   (>= (get paid rental) u0))
              ERR-BAD-ARGS)
    (ok true)))

;; Safely unwrap a listing with validation
(define-private (safe-get-listing (id uint))
  (match (map-get? listings {id: id})
    listing (begin
              (try! (validate-listing listing))
              (ok listing))
    ERR-NOT-FOUND))

;; Safely unwrap a rental with validation
(define-private (safe-get-rental (id uint))
  (match (get-rental id)
    rental (begin
             (try! (validate-rental rental))
             (ok rental))
    ERR-NOT-FOUND))

;; Safe map operations
(define-private (validate-id (id uint))
  (< id (var-get next-listing-id)))

(define-read-only (validate-map-id (id uint))
  (begin
    (asserts! (validate-id id) ERR-NOT-FOUND)
    (ok true)))
