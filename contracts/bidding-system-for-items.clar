(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-AUCTION-NOT-FOUND (err u101))
(define-constant ERR-AUCTION-ENDED (err u102))
(define-constant ERR-AUCTION-NOT-ENDED (err u103))
(define-constant ERR-BID-TOO-LOW (err u104))
(define-constant ERR-CANNOT-BID-OWN-AUCTION (err u105))
(define-constant ERR-AUCTION-ALREADY-FINALIZED (err u106))
(define-constant ERR-NO-BIDS (err u107))
(define-constant ERR-TRANSFER-FAILED (err u108))

(define-data-var auction-counter uint u0)

(define-map auctions
  { auction-id: uint }
  {
    seller: principal,
    item-name: (string-ascii 50),
    description: (string-ascii 200),
    starting-price: uint,
    current-bid: uint,
    highest-bidder: (optional principal),
    end-block: uint,
    finalized: bool
  }
)

(define-map bids
  { auction-id: uint, bidder: principal }
  { amount: uint, stacks-block-height: uint }
)

(define-map user-bids
  { bidder: principal }
  { total-bids: uint }
)

(define-read-only (get-auction (auction-id uint))
  (map-get? auctions { auction-id: auction-id })
)

(define-read-only (get-bid (auction-id uint) (bidder principal))
  (map-get? bids { auction-id: auction-id, bidder: bidder })
)

(define-read-only (get-user-bid-count (bidder principal))
  (default-to u0 (get total-bids (map-get? user-bids { bidder: bidder })))
)

(define-read-only (get-auction-counter)
  (var-get auction-counter)
)

(define-read-only (is-auction-active (auction-id uint))
  (match (get-auction auction-id)
    auction (< stacks-block-height (get end-block auction))
    false
  )
)

(define-read-only (get-time-remaining (auction-id uint))
  (match (get-auction auction-id)
    auction 
      (if (> (get end-block auction) stacks-block-height)
        (some (- (get end-block auction) stacks-block-height))
        (some u0)
      )
    none
  )
)

(define-public (create-auction (item-name (string-ascii 50)) (description (string-ascii 200)) (starting-price uint) (duration uint))
  (let
    (
      (auction-id (+ (var-get auction-counter) u1))
      (end-block (+ stacks-block-height duration))
    )
    (asserts! (> starting-price u0) ERR-BID-TOO-LOW)
    (asserts! (> duration u0) ERR-AUCTION-ENDED)
    
    (map-set auctions
      { auction-id: auction-id }
      {
        seller: tx-sender,
        item-name: item-name,
        description: description,
        starting-price: starting-price,
        current-bid: starting-price,
        highest-bidder: none,
        end-block: end-block,
        finalized: false
      }
    )
    
    (var-set auction-counter auction-id)
    (ok auction-id)
  )
)

(define-public (place-bid (auction-id uint) (bid-amount uint))
  (let
    (
      (auction (unwrap! (get-auction auction-id) ERR-AUCTION-NOT-FOUND))
      (current-bid (get current-bid auction))
      (seller (get seller auction))
    )
    (asserts! (not (is-eq tx-sender seller)) ERR-CANNOT-BID-OWN-AUCTION)
    (asserts! (< stacks-block-height (get end-block auction)) ERR-AUCTION-ENDED)
    (asserts! (> bid-amount current-bid) ERR-BID-TOO-LOW)
    (asserts! (not (get finalized auction)) ERR-AUCTION-ALREADY-FINALIZED)
    
    (try! (stx-transfer? bid-amount tx-sender (as-contract tx-sender)))
    
    (match (get highest-bidder auction)
      previous-bidder
        (begin
          (try! (as-contract (stx-transfer? current-bid tx-sender previous-bidder)))
          true
        )
      true
    )
    
    (map-set auctions
      { auction-id: auction-id }
      (merge auction {
        current-bid: bid-amount,
        highest-bidder: (some tx-sender)
      })
    )
    
    (map-set bids
      { auction-id: auction-id, bidder: tx-sender }
      { amount: bid-amount, stacks-block-height: stacks-block-height }
    )
    
    (map-set user-bids
      { bidder: tx-sender }
      { total-bids: (+ (get-user-bid-count tx-sender) u1) }
    )
    
    (ok true)
  )
)

(define-public (finalize-auction (auction-id uint))
  (let
    (
      (auction (unwrap! (get-auction auction-id) ERR-AUCTION-NOT-FOUND))
      (seller (get seller auction))
      (current-bid (get current-bid auction))
      (starting-price (get starting-price auction))
    )
    (asserts! (>= stacks-block-height (get end-block auction)) ERR-AUCTION-NOT-ENDED)
    (asserts! (not (get finalized auction)) ERR-AUCTION-ALREADY-FINALIZED)
    
    (match (get highest-bidder auction)
      winner
        (begin
          (try! (as-contract (stx-transfer? current-bid tx-sender seller)))
          (map-set auctions
            { auction-id: auction-id }
            (merge auction { finalized: true })
          )
          (ok { winner: (some winner), final-price: current-bid })
        )
      (begin
        (map-set auctions
          { auction-id: auction-id }
          (merge auction { finalized: true })
        )
        (ok { winner: none, final-price: u0 })
      )
    )
  )
)

(define-public (cancel-auction (auction-id uint))
  (let
    (
      (auction (unwrap! (get-auction auction-id) ERR-AUCTION-NOT-FOUND))
      (seller (get seller auction))
      (current-bid (get current-bid auction))
      (starting-price (get starting-price auction))
    )
    (asserts! (is-eq tx-sender seller) ERR-NOT-AUTHORIZED)
    (asserts! (< stacks-block-height (get end-block auction)) ERR-AUCTION-ENDED)
    (asserts! (not (get finalized auction)) ERR-AUCTION-ALREADY-FINALIZED)
    
    (match (get highest-bidder auction)
      bidder
        (begin
          (try! (as-contract (stx-transfer? current-bid tx-sender bidder)))
          (map-set auctions
            { auction-id: auction-id }
            (merge auction { 
              finalized: true,
              end-block: stacks-block-height
            })
          )
          (ok true)
        )
      (begin
        (map-set auctions
          { auction-id: auction-id }
          (merge auction { 
            finalized: true,
            end-block: stacks-block-height
          })
        )
        (ok true)
      )
    )
  )
)

(define-read-only (get-auction-status (auction-id uint))
  (match (get-auction auction-id)
    auction
      (if (get finalized auction)
        "finalized"
        (if (< stacks-block-height (get end-block auction))
          "active"
          "ended"
        )
      )
    "not-found"
  )
)

(define-read-only (get-auction-summary (auction-id uint))
  (match (get-auction auction-id)
    auction
      (some {
        auction-id: auction-id,
        item-name: (get item-name auction),
        current-bid: (get current-bid auction),
        highest-bidder: (get highest-bidder auction),
        time-remaining: (unwrap-panic (get-time-remaining auction-id)),
        status: (get-auction-status auction-id)
      })
    none
  )
)