;; Time Currency Ledger Contract
;; Hour-based exchange tracking and community service documentation
;; Manages time credits, service exchanges, and community pooling

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only u100)
(define-constant err-unauthorized u101)
(define-constant err-insufficient-balance u102)
(define-constant err-invalid-amount u103)
(define-constant err-service-not-found u104)
(define-constant err-already-completed u105)
(define-constant err-invalid-status u106)
(define-constant err-self-service u107)
(define-constant err-not-found u108)

;; Data Variables
(define-data-var service-id-counter uint u0)
(define-data-var transaction-id-counter uint u0)
(define-data-var community-pool-balance uint u0)
(define-data-var total-credits-issued uint u0)
(define-data-var total-services-completed uint u0)
(define-data-var active-services-count uint u0)

;; Data Maps
;; User time credit balances and profiles
(define-map user-balances
  { user: principal }
  {
    time-credits: uint,
    total-earned: uint,
    total-spent: uint,
    services-provided: uint,
    services-received: uint,
    reputation-score: uint,
    joined-at: uint
  }
)

;; Service exchange records
(define-map services
  { service-id: uint }
  {
    provider: principal,
    requester: principal,
    description: (string-ascii 200),
    category: (string-ascii 50),
    hours-estimated: uint,
    hours-actual: uint,
    status: (string-ascii 20),
    created-at: uint,
    completed-at: uint,
    credits-amount: uint
  }
)

;; Transaction history for all credit movements
(define-map transactions
  { transaction-id: uint }
  {
    from: principal,
    to: principal,
    amount: uint,
    transaction-type: (string-ascii 30),
    service-id: (optional uint),
    timestamp: uint,
    description: (string-ascii 100)
  }
)

;; Community pool contributions and usage
(define-map pool-contributions
  { contributor: principal }
  {
    total-contributed: uint,
    last-contribution: uint,
    contribution-count: uint
  }
)

;; Service ratings and feedback
(define-map service-ratings
  { service-id: uint }
  {
    rating: uint,
    feedback: (string-ascii 200),
    rated-by: principal,
    rated-at: uint
  }
)

;; Public Functions

;; Register a new user in the time banking system
(define-public (register-user)
  (let (
    (current-block stacks-block-height)
  )
    ;; Check if user already exists
    (match (map-get? user-balances { user: tx-sender })
      existing-user (err err-already-completed)
      ;; Create new user profile with initial credits
      (begin
        (map-set user-balances { user: tx-sender }
          {
            time-credits: u10, ;; Welcome bonus
            total-earned: u10,
            total-spent: u0,
            services-provided: u0,
            services-received: u0,
            reputation-score: u100,
            joined-at: current-block
          }
        )
        (var-set total-credits-issued (+ (var-get total-credits-issued) u10))
        (ok true)
      )
    )
  )
)

;; Post a new service request
(define-public (post-service-request (description (string-ascii 200))
                                   (category (string-ascii 50))
                                   (hours-estimated uint))
  (let (
    (new-service-id (+ (var-get service-id-counter) u1))
    (current-block stacks-block-height)
  )
    ;; Validate inputs
    (asserts! (> hours-estimated u0) (err err-invalid-amount))
    ;; Ensure user is registered
    (unwrap! (map-get? user-balances { user: tx-sender }) (err err-not-found))
    ;; Create service request
    (map-set services { service-id: new-service-id }
      {
        provider: tx-sender, ;; Will be updated when someone accepts
        requester: tx-sender,
        description: description,
        category: category,
        hours-estimated: hours-estimated,
        hours-actual: u0,
        status: "open",
        created-at: current-block,
        completed-at: u0,
        credits-amount: hours-estimated
      }
    )
    ;; Update counters
    (var-set service-id-counter new-service-id)
    (var-set active-services-count (+ (var-get active-services-count) u1))
    (ok new-service-id)
  )
)

;; Accept and provide a service
(define-public (provide-service (service-id uint) (hours-actual uint))
  (let (
    (service (unwrap! (map-get? services { service-id: service-id }) (err err-service-not-found)))
    (provider-balance (unwrap! (map-get? user-balances { user: tx-sender }) (err err-not-found)))
    (requester-balance (unwrap! (map-get? user-balances { user: (get requester service) }) (err err-not-found)))
    (current-block stacks-block-height)
    (credits-to-earn hours-actual)
  )
    ;; Validate service can be provided
    (asserts! (is-eq (get status service) "open") (err err-invalid-status))
    (asserts! (not (is-eq tx-sender (get requester service))) (err err-self-service))
    (asserts! (> hours-actual u0) (err err-invalid-amount))
    ;; Check if requester has sufficient credits
    (asserts! (>= (get time-credits requester-balance) credits-to-earn) (err err-insufficient-balance))
    ;; Update service status
    (map-set services { service-id: service-id }
      (merge service {
        provider: tx-sender,
        hours-actual: hours-actual,
        status: "completed",
        completed-at: current-block,
        credits-amount: credits-to-earn
      })
    )
    ;; Transfer credits from requester to provider
    (map-set user-balances { user: tx-sender }
      (merge provider-balance {
        time-credits: (+ (get time-credits provider-balance) credits-to-earn),
        total-earned: (+ (get total-earned provider-balance) credits-to-earn),
        services-provided: (+ (get services-provided provider-balance) u1),
        reputation-score: (+ (get reputation-score provider-balance) u5)
      })
    )
    (map-set user-balances { user: (get requester service) }
      (merge requester-balance {
        time-credits: (- (get time-credits requester-balance) credits-to-earn),
        total-spent: (+ (get total-spent requester-balance) credits-to-earn),
        services-received: (+ (get services-received requester-balance) u1)
      })
    )
    ;; Record transaction
    (record-transaction (get requester service) tx-sender credits-to-earn "service-payment" (some service-id) "Service payment")
    ;; Update system counters
    (var-set total-services-completed (+ (var-get total-services-completed) u1))
    (var-set active-services-count (- (var-get active-services-count) u1))
    (ok true)
  )
)

;; Transfer time credits between users
(define-public (transfer-credits (to principal) (amount uint) (description (string-ascii 100)))
  (let (
    (sender-balance (unwrap! (map-get? user-balances { user: tx-sender }) (err err-not-found)))
    (recipient-balance (unwrap! (map-get? user-balances { user: to }) (err err-not-found)))
  )
    ;; Validate transfer
    (asserts! (> amount u0) (err err-invalid-amount))
    (asserts! (>= (get time-credits sender-balance) amount) (err err-insufficient-balance))
    (asserts! (not (is-eq tx-sender to)) (err err-self-service))
    ;; Execute transfer
    (map-set user-balances { user: tx-sender }
      (merge sender-balance {
        time-credits: (- (get time-credits sender-balance) amount),
        total-spent: (+ (get total-spent sender-balance) amount)
      })
    )
    (map-set user-balances { user: to }
      (merge recipient-balance {
        time-credits: (+ (get time-credits recipient-balance) amount),
        total-earned: (+ (get total-earned recipient-balance) amount)
      })
    )
    ;; Record transaction
    (record-transaction tx-sender to amount "peer-transfer" none description)
    (ok true)
  )
)

;; Contribute to community pool
(define-public (contribute-to-pool (amount uint))
  (let (
    (user-balance (unwrap! (map-get? user-balances { user: tx-sender }) (err err-not-found)))
    (current-contribution (default-to 
      { total-contributed: u0, last-contribution: u0, contribution-count: u0 }
      (map-get? pool-contributions { contributor: tx-sender })
    ))
    (current-block stacks-block-height)
  )
    ;; Validate contribution
    (asserts! (> amount u0) (err err-invalid-amount))
    (asserts! (>= (get time-credits user-balance) amount) (err err-insufficient-balance))
    ;; Execute contribution
    (map-set user-balances { user: tx-sender }
      (merge user-balance {
        time-credits: (- (get time-credits user-balance) amount),
        total-spent: (+ (get total-spent user-balance) amount)
      })
    )
    (var-set community-pool-balance (+ (var-get community-pool-balance) amount))
    (map-set pool-contributions { contributor: tx-sender }
      {
        total-contributed: (+ (get total-contributed current-contribution) amount),
        last-contribution: current-block,
        contribution-count: (+ (get contribution-count current-contribution) u1)
      }
    )
    ;; Record transaction
    (record-transaction tx-sender contract-owner amount "pool-contribution" none "Community pool contribution")
    (ok true)
  )
)

;; Rate a completed service
(define-public (rate-service (service-id uint) (rating uint) (feedback (string-ascii 200)))
  (let (
    (service (unwrap! (map-get? services { service-id: service-id }) (err err-service-not-found)))
    (current-block stacks-block-height)
  )
    ;; Validate rating
    (asserts! (is-eq (get status service) "completed") (err err-invalid-status))
    (asserts! (is-eq tx-sender (get requester service)) (err err-unauthorized))
    (asserts! (and (>= rating u1) (<= rating u5)) (err err-invalid-amount))
    ;; Record rating
    (map-set service-ratings { service-id: service-id }
      {
        rating: rating,
        feedback: feedback,
        rated-by: tx-sender,
        rated-at: current-block
      }
    )
    ;; Update provider reputation based on rating
    (let (
      (provider-balance (unwrap! (map-get? user-balances { user: (get provider service) }) (err err-not-found)))
    )
      (map-set user-balances { user: (get provider service) }
        (merge provider-balance {
          reputation-score: (+ (get reputation-score provider-balance) rating)
        })
      )
    )
    (ok true)
  )
)

;; Read-only Functions

;; Get user balance and profile information
(define-read-only (get-user-balance (user principal))
  (map-get? user-balances { user: user })
)

;; Get service details
(define-read-only (get-service (service-id uint))
  (map-get? services { service-id: service-id })
)

;; Get transaction details
(define-read-only (get-transaction (transaction-id uint))
  (map-get? transactions { transaction-id: transaction-id })
)

;; Get service rating
(define-read-only (get-service-rating (service-id uint))
  (map-get? service-ratings { service-id: service-id })
)

;; Get community pool information
(define-read-only (get-community-pool-info)
  {
    pool-balance: (var-get community-pool-balance),
    total-credits-issued: (var-get total-credits-issued),
    total-services-completed: (var-get total-services-completed),
    active-services-count: (var-get active-services-count)
  }
)

;; Get user's pool contributions
(define-read-only (get-pool-contributions (contributor principal))
  (map-get? pool-contributions { contributor: contributor })
)

;; Private Functions

;; Record a transaction in the system
(define-private (record-transaction (from principal) (to principal) (amount uint) 
                                   (transaction-type (string-ascii 30)) 
                                   (service-id (optional uint)) 
                                   (description (string-ascii 100)))
  (let (
    (new-transaction-id (+ (var-get transaction-id-counter) u1))
    (current-block stacks-block-height)
  )
    (map-set transactions { transaction-id: new-transaction-id }
      {
        from: from,
        to: to,
        amount: amount,
        transaction-type: transaction-type,
        service-id: service-id,
        timestamp: current-block,
        description: description
      }
    )
    (var-set transaction-id-counter new-transaction-id)
    true
  )
)
