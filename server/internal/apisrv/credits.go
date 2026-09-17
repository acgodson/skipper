package apisrv

import (
	"errors"
	"net/http"
	"strings"

	"rc-signal/internal/apidb"
	"rc-signal/internal/policy"
	protocol "rcprotocol"
)

func (s *Server) credits(w http.ResponseWriter, r *http.Request) {
	account, ok := s.userSession(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitCredits, account.AccountID) {
		return
	}
	if err := s.opt.DB.ExpirePendingGifts(s.nowMS()); err != nil {
		s.internalError(w, r, err)
		return
	}
	balance, err := s.opt.DB.Balance(account.AccountID)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	updatedAt, err := s.opt.DB.BalanceUpdatedAt(account.AccountID)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	if updatedAt == 0 {
		updatedAt = account.CreatedAt
	}
	s.writeJSON(w, r, http.StatusOK, protocol.Balance{
		BalanceCents: balance, Currency: protocol.CurrencyUSD, UpdatedAt: updatedAt,
	})
}

func (s *Server) creditsLedger(w http.ResponseWriter, r *http.Request) {
	account, ok := s.userSession(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitLedger, account.AccountID) {
		return
	}
	if !knownQuery(r, "since", "until", "cursor", "limit") {
		s.badRequest(w, r, "unknown query parameter")
		return
	}
	since, ok := s.msQuery(w, r, "since", true)
	if !ok {
		return
	}
	until, ok := s.msQuery(w, r, "until", false)
	if !ok {
		return
	}
	limit, ok := s.intQuery(w, r, "limit", protocol.DefaultHistoryPageLimit, 1, protocol.MaxHistoryPageLimit)
	if !ok {
		return
	}
	after, afterID, valid := s.decodeCursor(r.URL.Query().Get("cursor"))
	if !valid {
		s.badRequest(w, r, "that cursor is not usable")
		return
	}
	entries, err := s.opt.DB.ListLedger(apidb.LedgerQuery{
		AccountID: account.AccountID, Since: since, Until: until,
		After: after, AfterID: afterID, Limit: limit + 1,
	})
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	page := protocol.LedgerPage{Entries: []protocol.LedgerEntry{}}
	for i, e := range entries {
		if i == limit {
			page.NextCursor = encodeCursor(entries[i-1].CreatedAt, entries[i-1].EntryID, s.nowMS())
			break
		}
		page.Entries = append(page.Entries, e)
	}
	s.writeJSON(w, r, http.StatusOK, page)
}

// TODO: payments. API.md §7.4 replaces this with POST /v1/credits/topup and the
// provider webhook; this endpoint exists only under the dev identity provider.
type devTopupRequest struct {
	AmountCents int64 `json:"amountCents"`
}

func (s *Server) devTopup(w http.ResponseWriter, r *http.Request) {
	if s.opt.IdP.Name() != "dev" {
		s.fail(w, r, http.StatusNotFound, protocol.APIErrNotFound, "no such path")
		return
	}
	account, ok := s.userSession(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitCredits, account.AccountID) {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	s.idempotent(w, r, account.AccountID, body, replayable, func(w http.ResponseWriter) {
		var req devTopupRequest
		if !s.decode(w, r, body, &req) {
			return
		}
		if req.AmountCents <= 0 {
			s.badRequest(w, r, "'amountCents' must be positive")
			return
		}
		entry, err := s.opt.DB.Append(account.AccountID, protocol.LedgerTopup, req.AmountCents,
			s.nowMS(), "", "", "development top-up")
		if err != nil {
			s.internalError(w, r, err)
			return
		}
		s.writeJSON(w, r, http.StatusCreated, entry)
	})
}

func (s *Server) createGift(w http.ResponseWriter, r *http.Request) {
	account, ok := s.userSession(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitGiftCreate, account.AccountID) {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	s.idempotent(w, r, account.AccountID, body, replayable, func(w http.ResponseWriter) {
		var req protocol.CreateGiftRequest
		if !s.decode(w, r, body, &req) {
			return
		}
		toEmail := apidb.NormaliseEmail(req.ToEmail)
		if toEmail == "" || !strings.Contains(toEmail, "@") {
			s.badRequest(w, r, "'toEmail' must be an email address")
			return
		}
		if toEmail == account.Email {
			s.badRequest(w, r, "a gift cannot be sent to the sender's own address")
			return
		}
		if req.AmountCents < policy.MinGiftCents {
			s.badRequest(w, r, "'amountCents' is below the minimum gift")
			return
		}
		if len(req.Message) > protocol.MaxGiftMessageLen {
			s.badRequest(w, r, "'message' is longer than 280 characters")
			return
		}
		balance, err := s.opt.DB.Balance(account.AccountID)
		if err != nil {
			s.internalError(w, r, err)
			return
		}
		if balance < req.AmountCents {
			s.fail(w, r, http.StatusPaymentRequired, protocol.APIErrEntitlement,
				"the balance does not cover that gift", withReason(protocol.EntitlementNoBalance))
			return
		}
		now := s.nowMS()
		gift := apidb.Gift{
			GiftID: apidb.NewID("gift_"), FromAccountID: account.AccountID, FromEmail: account.Email,
			ToEmail: toEmail, AmountCents: req.AmountCents, Message: req.Message,
			Status: protocol.GiftPending, CreatedAt: now,
			ExpiresAt: now + int64(protocol.GiftTTLSec)*1000,
		}
		if err := s.opt.DB.PutGift(gift); err != nil {
			s.internalError(w, r, err)
			return
		}
		if _, err := s.opt.DB.Append(account.AccountID, protocol.LedgerGiftSent, -gift.AmountCents,
			now, "", gift.GiftID, "gift held"); err != nil {
			s.internalError(w, r, err)
			return
		}
		s.writeJSON(w, r, http.StatusCreated, gift.Public())
	})
}

func (s *Server) listGifts(w http.ResponseWriter, r *http.Request) {
	account, ok := s.userSession(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitGiftList, account.AccountID) {
		return
	}
	if !knownQuery(r, "direction", "status", "cursor", "limit") {
		s.badRequest(w, r, "unknown query parameter")
		return
	}
	if err := s.opt.DB.ExpirePendingGifts(s.nowMS()); err != nil {
		s.internalError(w, r, err)
		return
	}
	query := apidb.GiftQuery{Status: r.URL.Query().Get("status")}
	switch r.URL.Query().Get("direction") {
	case protocol.GiftDirectionSent:
		query.FromAccountID = account.AccountID
	case protocol.GiftDirectionReceived:
		query.ToEmail = account.Email
	default:
		s.badRequest(w, r, "'direction' must be 'sent' or 'received'")
		return
	}
	limit, ok := s.intQuery(w, r, "limit", protocol.DefaultPageLimit, 1, protocol.MaxHistoryPageLimit)
	if !ok {
		return
	}
	after, afterID, valid := s.decodeCursor(r.URL.Query().Get("cursor"))
	if !valid {
		s.badRequest(w, r, "that cursor is not usable")
		return
	}
	query.After, query.AfterID, query.Limit = after, afterID, limit+1
	gifts, err := s.opt.DB.ListGifts(query)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	page := protocol.GiftList{Gifts: []protocol.Gift{}}
	for i, g := range gifts {
		if i == limit {
			page.NextCursor = encodeCursor(gifts[i-1].CreatedAt, gifts[i-1].GiftID, s.nowMS())
			break
		}
		page.Gifts = append(page.Gifts, g.Public())
	}
	s.writeJSON(w, r, http.StatusOK, page)
}

func (s *Server) giftForCaller(w http.ResponseWriter, r *http.Request, account *apidb.Account, sender bool) (*apidb.Gift, bool) {
	gift, err := s.opt.DB.Gift(r.PathValue("giftId"))
	if errors.Is(err, apidb.ErrNotFound) {
		s.fail(w, r, http.StatusNotFound, protocol.APIErrNotFound, "no such gift")
		return nil, false
	}
	if err != nil {
		s.internalError(w, r, err)
		return nil, false
	}
	owns := gift.ToEmail == account.Email
	if sender {
		owns = gift.FromAccountID == account.AccountID
	}
	if !owns {
		s.fail(w, r, http.StatusForbidden, protocol.APIErrForbidden, "that gift belongs to someone else")
		return nil, false
	}
	if gift.Status != protocol.GiftPending {
		s.fail(w, r, http.StatusConflict, protocol.APIErrConflict, "that gift is no longer pending")
		return nil, false
	}
	return gift, true
}

func (s *Server) acceptGift(w http.ResponseWriter, r *http.Request) {
	account, ok := s.userSession(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitGiftAct, account.AccountID) {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	s.idempotent(w, r, account.AccountID, body, replayable, func(w http.ResponseWriter) {
		if err := s.opt.DB.ExpirePendingGifts(s.nowMS()); err != nil {
			s.internalError(w, r, err)
			return
		}
		gift, ok := s.giftForCaller(w, r, account, false)
		if !ok {
			return
		}
		now := s.nowMS()
		if err := s.opt.DB.SetGiftStatus(gift.GiftID, protocol.GiftAccepted, &now); err != nil {
			s.fail(w, r, http.StatusConflict, protocol.APIErrConflict, "that gift is no longer pending")
			return
		}
		if _, err := s.opt.DB.Append(account.AccountID, protocol.LedgerGiftReceived, gift.AmountCents,
			now, "", gift.GiftID, "gift from "+gift.FromEmail); err != nil {
			s.internalError(w, r, err)
			return
		}
		gift.Status = protocol.GiftAccepted
		gift.AcceptedAt = &now
		s.writeJSON(w, r, http.StatusOK, gift.Public())
	})
}

func (s *Server) cancelGift(w http.ResponseWriter, r *http.Request) {
	account, ok := s.userSession(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitGiftAct, account.AccountID) {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	s.idempotent(w, r, account.AccountID, body, replayable, func(w http.ResponseWriter) {
		gift, ok := s.giftForCaller(w, r, account, true)
		if !ok {
			return
		}
		if err := s.opt.DB.SetGiftStatus(gift.GiftID, protocol.GiftCancelled, nil); err != nil {
			s.fail(w, r, http.StatusConflict, protocol.APIErrConflict, "that gift is no longer pending")
			return
		}
		now := s.nowMS()
		if _, err := s.opt.DB.Append(account.AccountID, protocol.LedgerGiftRefund, gift.AmountCents,
			now, "", gift.GiftID, "gift cancelled"); err != nil {
			s.internalError(w, r, err)
			return
		}
		gift.Status = protocol.GiftCancelled
		s.writeJSON(w, r, http.StatusOK, gift.Public())
	})
}
