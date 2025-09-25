;; Labor Equity Framework Contract
;; Fair valuation of different types of community contributions
;; Democratic management of service categories, standards, and disputes

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only u200)
(define-constant err-unauthorized u201)
(define-constant err-invalid-input u202)
(define-constant err-not-found u203)
(define-constant err-already-exists u204)
(define-constant err-invalid-status u205)
(define-constant err-quota-exceeded u206)
(define-constant err-duplicate-vote u207)
(define-constant err-timeout u208)

;; Data Variables
(define-data-var category-id-counter uint u0)
(define-data-var proposal-id-counter uint u0)
(define-data-var dispute-id-counter uint u0)
(define-data-var total-members uint u0)
(define-data-var active-proposals uint u0)

;; Data Maps
;; Community membership registry
(define-map members
  { user: principal }
  {
    joined-at: uint,
    reputation: uint,
    endorsements: uint,
    active: bool
  }
)

;; Service categories with community standards
(define-map service-categories
  { category-id: uint }
  {
    name: (string-ascii 50),
    description: (string-ascii 200),
    base-rate: uint, ;; base guidance rate in time units per hour (always 1 for equality, but adjustable for guidance)
    safety-standard: (string-ascii 100),
    quality-standard: (string-ascii 100),
    created-by: principal,
    created-at: uint,
    active: bool
  }
)

;; Governance proposals (add/update category, policy, etc.)
(define-map proposals
  { proposal-id: uint }
  {
    proposer: principal,
    proposal-type: (string-ascii 30),
    title: (string-ascii 80),
    content: (string-ascii 300),
    target-id: (optional uint),
    created-at: uint,
    deadline: uint,
    for-votes: uint,
    against-votes: uint,
    status: (string-ascii 20)
  }
)

;; Votes registry to prevent duplicate voting
(define-map votes
  { proposal-id: uint, voter: principal }
  { support: bool }
)

;; Dispute records between participants
(define-map disputes
  { dispute-id: uint }
  {
    raised-by: principal,
    against: principal,
    category-id: uint,
    description: (string-ascii 200),
    status: (string-ascii 20),
    created-at: uint,
    resolved-at: uint,
    resolution-notes: (string-ascii 200)
  }
)

;; Endorsements for skills
(define-map endorsements
  { user: principal, category-id: uint }
  {
    endorsers: uint,
    last-endorsed: uint
  }
)

;; Public Functions

;; Join the equity framework as a community member
(define-public (join-community)
  (let (
    (current-block stacks-block-height)
  )
    (match (map-get? members { user: tx-sender })
      existing (err err-already-exists)
      (begin
        (map-set members { user: tx-sender }
          { joined-at: current-block, reputation: u100, endorsements: u0, active: true }
        )
        (var-set total-members (+ (var-get total-members) u1))
        (ok true)
      )
    )
  )
)

;; Create a new service category
(define-public (create-category (name (string-ascii 50))
                               (description (string-ascii 200))
                               (safety-standard (string-ascii 100))
                               (quality-standard (string-ascii 100)))
  (let (
    (current-block stacks-block-height)
    (new-category-id (+ (var-get category-id-counter) u1))
  )
    (asserts! (> (len name) u0) (err err-invalid-input))
    (unwrap! (map-get? members { user: tx-sender }) (err err-unauthorized))
    (map-set service-categories { category-id: new-category-id }
      {
        name: name,
        description: description,
        base-rate: u1,
        safety-standard: safety-standard,
        quality-standard: quality-standard,
        created-by: tx-sender,
        created-at: current-block,
        active: true
      }
    )
    (var-set category-id-counter new-category-id)
    (ok new-category-id)
  )
)

;; Propose a governance change (e.g., update a category's standards)
(define-public (propose (proposal-type (string-ascii 30))
                       (title (string-ascii 80))
                       (content (string-ascii 300))
                       (target-id (optional uint))
                       (duration uint))
  (let (
    (member (unwrap! (map-get? members { user: tx-sender }) (err err-unauthorized)))
    (current-block stacks-block-height)
    (new-proposal-id (+ (var-get proposal-id-counter) u1))
    (deadline (+ stacks-block-height duration))
  )
    (asserts! (> duration u0) (err err-invalid-input))
    (map-set proposals { proposal-id: new-proposal-id }
      {
        proposer: tx-sender,
        proposal-type: proposal-type,
        title: title,
        content: content,
        target-id: target-id,
        created-at: current-block,
        deadline: deadline,
        for-votes: u0,
        against-votes: u0,
        status: "active"
      }
    )
    (var-set proposal-id-counter new-proposal-id)
    (var-set active-proposals (+ (var-get active-proposals) u1))
    (ok new-proposal-id)
  )
)

;; Vote on a proposal
(define-public (vote (proposal-id uint) (support bool))
  (let (
    (member (unwrap! (map-get? members { user: tx-sender }) (err err-unauthorized)))
    (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) (err err-not-found)))
  )
    (asserts! (is-eq (get status proposal) "active") (err err-invalid-status))
    (asserts! (> (get reputation member) u0) (err err-unauthorized))
    (asserts! (> (get deadline proposal) stacks-block-height) (err err-timeout))
    ;; Prevent duplicate voting
    (match (map-get? votes { proposal-id: proposal-id, voter: tx-sender })
      existing (err err-duplicate-vote)
      (begin
        (map-set votes { proposal-id: proposal-id, voter: tx-sender } { support: support })
        (map-set proposals { proposal-id: proposal-id }
          (merge proposal {
            for-votes: (+ (get for-votes proposal) (if support u1 u0)),
            against-votes: (+ (get against-votes proposal) (if support u0 u1))
          })
        )
        (ok true)
      )
    )
  )
)

;; Finalize proposal after deadline
(define-public (finalize-proposal (proposal-id uint))
  (let (
    (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) (err err-not-found)))
  )
    (asserts! (> stacks-block-height (get deadline proposal)) (err err-timeout))
    (asserts! (is-eq (get status proposal) "active") (err err-invalid-status))
    (map-set proposals { proposal-id: proposal-id }
      (merge proposal {
        status: (if (>= (get for-votes proposal) (get against-votes proposal)) "accepted" "rejected")
      })
    )
    (var-set active-proposals (- (var-get active-proposals) u1))
    (ok true)
  )
)

;; Raise a dispute related to a service category interaction
(define-public (raise-dispute (against principal) (category-id uint) (description (string-ascii 200)))
  (let (
    (current-block stacks-block-height)
    (category (unwrap! (map-get? service-categories { category-id: category-id }) (err err-not-found)))
    (new-dispute-id (+ (var-get dispute-id-counter) u1))
  )
    (asserts! (not (is-eq tx-sender against)) (err err-invalid-input))
    (map-set disputes { dispute-id: new-dispute-id }
      {
        raised-by: tx-sender,
        against: against,
        category-id: category-id,
        description: description,
        status: "open",
        created-at: current-block,
        resolved-at: u0,
        resolution-notes: ""
      }
    )
    (var-set dispute-id-counter new-dispute-id)
    (ok new-dispute-id)
  )
)

;; Resolve a dispute (mediator role simulated by contract owner for simplicity)
(define-public (resolve-dispute (dispute-id uint) (notes (string-ascii 200)))
  (let (
    (dispute (unwrap! (map-get? disputes { dispute-id: dispute-id }) (err err-not-found)))
    (current-block stacks-block-height)
  )
    (asserts! (is-eq tx-sender contract-owner) (err err-owner-only))
    (asserts! (is-eq (get status dispute) "open") (err err-invalid-status))
    (map-set disputes { dispute-id: dispute-id }
      (merge dispute {
        status: "resolved",
        resolved-at: current-block,
        resolution-notes: notes
      })
    )
    (ok true)
  )
)

;; Endorse a member's skill in a category
(define-public (endorse (user principal) (category-id uint))
  (let (
    (category (unwrap! (map-get? service-categories { category-id: category-id }) (err err-not-found)))
    (member (unwrap! (map-get? members { user: user }) (err err-not-found)))
    (current-block stacks-block-height)
    (endorsement (default-to { endorsers: u0, last-endorsed: u0 } (map-get? endorsements { user: user, category-id: category-id })))
  )
    (asserts! (not (is-eq tx-sender user)) (err err-invalid-input))
    (map-set endorsements { user: user, category-id: category-id }
      {
        endorsers: (+ (get endorsers endorsement) u1),
        last-endorsed: current-block
      }
    )
    ;; Boost reputation slightly
    (map-set members { user: user }
      (merge member { reputation: (+ (get reputation member) u1), endorsements: (+ (get endorsements member) u1) })
    )
    (ok true)
  )
)

;; Read-only Functions

(define-read-only (get-member (user principal))
  (map-get? members { user: user })
)

(define-read-only (get-category (category-id uint))
  (map-get? service-categories { category-id: category-id })
)

(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals { proposal-id: proposal-id })
)

(define-read-only (get-dispute (dispute-id uint))
  (map-get? disputes { dispute-id: dispute-id })
)

(define-read-only (get-endorsement (user principal) (category-id uint))
  (map-get? endorsements { user: user, category-id: category-id })
)

(define-read-only (get-stats)
  {
    total-members: (var-get total-members),
    categories: (var-get category-id-counter),
    proposals: (var-get proposal-id-counter),
    active-proposals: (var-get active-proposals),
    disputes: (var-get dispute-id-counter)
  }
)

;; Private helpers could go here if needed (none required for now)
