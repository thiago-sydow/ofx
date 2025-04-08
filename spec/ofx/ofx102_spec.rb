require "spec_helper"

describe OFX::Parser::OFX102 do
  before do
    @ofx = OFX::Parser::Base.new("spec/fixtures/sample.ofx")
    @parser = @ofx.parser
  end

  it "has a version" do
    expect(OFX::Parser::OFX102::VERSION).to eql "1.0.2"
  end

  it "sets headers" do
    expect(@parser.headers).to eql @ofx.headers
  end

  it "trims trailing whitespace from headers" do
    headers = OFX::Parser::OFX102.parse_headers("VERSION:102   ")
    expect(headers["VERSION"]).to eql "102"
  end

  it "sets body" do
    expect(@parser.body).to eql @ofx.body
  end

  it "sets account" do
    expect(@parser.account).to be_a_kind_of(OFX::Account)
  end

  it "sets account" do
    expect(@parser.sign_on).to be_a_kind_of(OFX::SignOn)
  end

  it "sets statements" do
    expect(@parser.statements.size).to eql 1
    expect(@parser.statements.first).to be_a_kind_of(OFX::Statement)
  end

  it "knows about all transaction types" do
    valid_types = [
      'CREDIT', 'DEBIT', 'INT', 'DIV', 'FEE', 'SRVCHG', 'DEP', 'ATM', 'POS', 'XFER',
      'CHECK', 'PAYMENT', 'CASH', 'DIRECTDEP', 'DIRECTDEBIT', 'REPEATPMT', 'OTHER'
    ]
    expect(valid_types.sort).to eql OFX::Parser::OFX102::TRANSACTION_TYPES.keys.sort

    valid_types.each do |transaction_type|
      expect(transaction_type.downcase.to_sym).to eql OFX::Parser::OFX102::TRANSACTION_TYPES[transaction_type]
    end
  end

  describe "multiple currencies accounts" do
    let(:parser) { OFX::Parser::Base.new(File.read('spec/fixtures/extratoBS2.ofx')).parser }

    it "parses multiple currencies account" do
      expect(parser.accounts.size).to eql 1
      expect(parser.accounts.first).to be_a_kind_of(OFX::Account)
    end

    it "parses multiple currencies statements" do
      expect(parser.statements.size).to eql 5
      expect(parser.statements.map(&:currency)).to eql(["USD", "EUR", "GBP", "CAD", "AUD"])
      expect(parser.statements.first).to be_a_kind_of(OFX::Statement)
    end

    it "parses multiple currencies transactions" do
      transactions = parser.statements.map(&:transactions).flatten

      expect(transactions.size).to eql 2

      expect(transactions.first.fit_id).to eql("107472")
      expect(transactions.first.amount_in_pennies).to eql(2_752_32)

      expect(transactions.last.fit_id).to eql("107475")
      expect(transactions.last.amount_in_pennies).to eql(1_000_00)
    end
  end

  describe "#build_date" do
    context "without a Time Zone" do
      it "defaults to GMT" do
        expect(@parser.send(:build_date, "20170904")).to eql Time.gm(2017, 9, 4)
        expect(@parser.send(:build_date, "20170904082855")).to eql Time.gm(2017, 9, 4, 8, 28, 55)
      end
    end

    context "with a Time Zone" do
      it "returns the correct date" do
        expect(@parser.send(:build_date, "2025024171840[-3:GMT]")).to eql Time.new(2025, 2, 4, 17, 18, 40, "-03:00")
        expect(@parser.send(:build_date, "20150507164333[-0300:BRT]")).to eql Time.new(2015, 5, 7, 16, 43, 33, "-03:00")
        expect(@parser.send(:build_date, "20180507120000[0:GMT]")).to eql Time.gm(2018, 5, 7, 12)
        expect(@parser.send(:build_date, "20170904082855[-3:GMT]")).to eql Time.new(2017, 9, 4, 8, 28, 55, "-03:00")
      end
    end
  end
end
