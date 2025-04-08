# frozen_string_literal: true

module OFX
  module Parser
    class OFX102
      VERSION = '1.0.2'

      ACCOUNT_TYPES = {
        'CHECKING' => :checking,
        'SAVINGS' => :savings,
        'CREDITLINE' => :creditline,
        'MONEYMRKT' => :moneymrkt
      }.freeze

      TRANSACTION_TYPES = %w[
        ATM CASH CHECK CREDIT DEBIT DEP DIRECTDEBIT DIRECTDEP DIV
        FEE INT OTHER PAYMENT POS REPEATPMT SRVCHG XFER
      ].each_with_object({}) do |tran_type, hash|
        hash[tran_type] = tran_type.downcase.to_sym
      end

      SEVERITY = {
        'INFO' => :info,
        'WARN' => :warn,
        'ERROR' => :error
      }.freeze

      attr_reader :headers, :body, :html

      def initialize(options = {})
        @headers = options[:headers]
        @body = options[:body]
        @html = Nokogiri::HTML.parse(body)
      end

      def statements
        @statements ||= html.search('stmttrnrs, ccstmttrnrs').collect { |node| build_statements(node) }.flatten
      end

      def accounts
        return @accounts if defined?(@accounts)

        @accounts = html.search('stmttrnrs, ccstmttrnrs').collect { |node| build_accounts(node) }.flatten.uniq { |acct| acct.id }
      end

      # DEPRECATED: kept for legacy support
      def account
        @account ||= build_account(html.search('stmttrnrs, ccstmttrnrs').first)
      end

      def sign_on
        @sign_on ||= build_sign_on
      end

      def self.parse_headers(header_text)
        # Change single CR's to LF's to avoid issues with some banks
        header_text.gsub!(/\r(?!\n)/, "\n")

        # Parse headers. When value is NONE, convert it to nil.
        headers = header_text.to_enum(:each_line).each_with_object({}) do |line, memo|
          _, key, value = *line.match(/^(.*?):(.*?)\s*(\r?\n)*$/)

          unless key.nil?
            memo[key] = value == 'NONE' ? nil : value
          end
        end

        return headers unless headers.empty?
      end

      private

      def build_statements(node)
        stmrs_nodes = node.search('stmtrs, ccstmtrs')

        return stmrs_nodes.map { |stmrs_node| build_statement(stmrs_node, stmrs_node) } if stmrs_nodes.size > 1

        build_statement(node, stmrs_nodes)
      end

      def build_statement(node_for_account, node_for_statement)
        account = build_account(node_for_account)
        OFX::Statement.new(
          currency: node_for_statement.search('curdef').inner_text,
          start_date: build_date(node_for_statement.search('banktranlist > dtstart').inner_text),
          end_date: build_date(node_for_statement.search('banktranlist > dtend').inner_text),
          account: account,
          transactions: account.transactions,
          balance: account.balance,
          available_balance: account.available_balance
        )
      end

      def build_accounts(node)
        stmrs_nodes = node.search('stmtrs, ccstmtrs')

        return stmrs_nodes.map { |stmrs_node| build_account(stmrs_node) } if stmrs_nodes.size > 1

        build_account(node)
      end

      def build_account(node)
        OFX::Account.new({
                           bank_id: node.search('bankacctfrom > bankid').inner_text,
                           id: node.search('bankacctfrom > acctid, ccacctfrom > acctid').inner_text,
                           branch_id: node.search('bankacctfrom > branchid').inner_text,
                           type: ACCOUNT_TYPES[node.search('bankacctfrom > accttype').inner_text.to_s.upcase],
                           transactions: build_transactions(node),
                           balance: build_balance(node),
                           available_balance: build_available_balance(node),
                           currency: node.search('stmtrs > curdef, ccstmtrs > curdef').inner_text
                         })
      end

      def build_status(node)
        OFX::Status.new({
                          code: node.search('code').inner_text.to_i,
                          severity: SEVERITY[node.search('severity').inner_text],
                          message: node.search('message').inner_text
                        })
      end

      def build_sign_on
        OFX::SignOn.new({
                          language: html.search('signonmsgsrsv1 > sonrs > language').inner_text,
                          fi_id: html.search('signonmsgsrsv1 > sonrs > fi > fid').inner_text,
                          fi_name: html.search('signonmsgsrsv1 > sonrs > fi > org').inner_text,
                          status: build_status(html.search('signonmsgsrsv1 > sonrs > status'))
                        })
      end

      def build_transactions(node)
        node.search('banktranlist > stmttrn').collect do |element|
          build_transaction(element)
        end
      end

      def build_transaction(element)
        occurred_at = begin
          build_date(element.search('dtuser').inner_text)
        rescue StandardError
          nil
        end

        OFX::Transaction.new({
                               amount: build_amount(element),
                               amount_in_pennies: (build_amount(element) * 100).to_i,
                               fit_id: element.search('fitid').inner_text,
                               memo: element.search('memo').inner_text,
                               name: element.search('name').inner_text,
                               payee: element.search('payee').inner_text,
                               check_number: element.search('checknum').inner_text,
                               ref_number: element.search('refnum').inner_text,
                               posted_at: build_date(element.search('dtposted').inner_text),
                               occurred_at: occurred_at,
                               type: build_type(element),
                               sic: element.search('sic').inner_text
                             })
      end

      def build_type(element)
        TRANSACTION_TYPES[element.search('trntype').inner_text.to_s.upcase]
      end

      def build_amount(element)
        to_decimal(element.search('trnamt').inner_text)
      end

      # Input format is `YYYYMMDDHHMMSS.XXX[gmt offset[:tz name]]`
      def build_date(date)
        tz_pattern = /(?:\[([+-]?\d{1,4}):\S{3}\])?\z/

        date = date.insert(6, '0') if !Date.valid_date?(date[0..3].to_i, date[4..5].to_i, date[6..7].to_i)

        # Timezone offset handling
        date.sub!(tz_pattern, '')
        offset = Regexp.last_match(1)

        if offset
          # Offset padding
          _, hours, mins = *offset.match(/\A([+-]?\d{1,2})(\d{0,2})?\z/)
          offset = format('%+03d%02d', hours.to_i, mins.to_i)
        else
          offset = '+0000'
        end

        date << " #{offset}"

        Time.parse(date)
      end

      def build_balance(node)
        amount = to_decimal(node.search('ledgerbal > balamt').inner_text)
        posted_at = begin
          build_date(node.search('ledgerbal > dtasof').inner_text)
        rescue StandardError
          nil
        end

        OFX::Balance.new({
                           amount: amount,
                           amount_in_pennies: (amount * 100).to_i,
                           posted_at: posted_at
                         })
      end

      def build_available_balance(node)
        if node.search('availbal').size > 0
          amount = to_decimal(node.search('availbal > balamt').inner_text)

          OFX::Balance.new({
                             amount: amount,
                             amount_in_pennies: (amount * 100).to_i,
                             posted_at: build_date(node.search('availbal > dtasof').inner_text)
                           })
        end
      end

      def to_decimal(amount)
        BigDecimal(amount.to_s.gsub(',', '.'))
      rescue ArgumentError
        BigDecimal('0.0')
      end
    end
  end
end
