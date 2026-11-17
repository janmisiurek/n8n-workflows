/** Development-only transaction boundary. n8n owns orchestration and AI calls. */
@RestResource(urlMapping='/emfire-offers/v1/*')
global with sharing class EmfireOfferApi {
    public class OfferException extends Exception {}
    private static final String PREFIX = 'EMF DEMO - ';
    private static final String FIELDS = 'Id,Name,LastModifiedDate,Request_Key__c,Opportunity__c,Status__c,Revision__c,Instruction__c,Feedback__c,Snapshot__c,Proposal__c,Source_Hash__c,Execution_Id__c,Last_Error__c,Document_Id__c';

    @HttpGet global static void getRequest() { dispatch(false); }
    @HttpPost global static void postRequest() { dispatch(true); }

    private static void dispatch(Boolean isPost) {
        Savepoint sp = Database.setSavepoint();
        try {
            if (!FeatureManagement.checkPermission('Emfire_Offer_Access')) {
                respond(new Map<String,Object>{'httpStatus'=>403,'code'=>'FORBIDDEN','message'=>'Brak uprawnienia Emfire Offer Access.'}); return;
            }
            Organization org = [SELECT OrganizationType FROM Organization LIMIT 1];
            if (org.OrganizationType != 'Developer Edition') throw new OfferException('Ten pakiet działa wyłącznie w Developer Edition.');
            String path = RestContext.request.requestURI.substringAfterLast('/');
            Map<String,Object> b = isPost ? (Map<String,Object>)JSON.deserializeUntyped(RestContext.request.requestBody.toString()) : new Map<String,Object>();
            Map<String,Object> out;
            if (!isPost && path == 'catalog') {
                String pattern = PREFIX + '%';
                out = new Map<String,Object>{'opportunities'=>[SELECT Id,Name FROM Opportunity WHERE Name LIKE :pattern AND IsClosed=false ORDER BY Name LIMIT 20]};
            } else if (isPost && path == 'prepare') out = prepare(b);
            else if (isPost && path == 'draft') out = saveDraft(b);
            else if (isPost && path == 'decision') out = decide(b);
            else if (isPost && path == 'error') out = recordError(b);
            else if (isPost && path == 'status') out = result(loadOffer(required(b,'requestId',80),true));
            else out = new Map<String,Object>{'httpStatus'=>404,'code'=>'NOT_FOUND','message'=>'Nieznana operacja.'};
            respond(out);
        } catch (OfferException e) {
            Database.rollback(sp);
            respond(new Map<String,Object>{'httpStatus'=>422,'code'=>'VALIDATION','message'=>e.getMessage()});
        } catch (Exception e) {
            Database.rollback(sp);
            RestContext.response.statusCode = 500;
            respond(new Map<String,Object>{'httpStatus'=>500,'code'=>'TECHNICAL','message'=>'Operacja nie została zatwierdzona. Sprawdź wykonanie n8n.','type'=>e.getTypeName()});
        }
    }
    private static void respond(Map<String,Object> out) {
        // Business failures are envelopes; the n8n UI maps httpStatus to the browser response.
        RestContext.response.addHeader('Content-Type','application/json;charset=UTF-8');
        RestContext.response.responseBody = Blob.valueOf(JSON.serialize(out));
    }
    private static String required(Map<String,Object> b,String key,Integer maxLen) {
        Object raw = b.get(key);
        if (!(raw instanceof String) || String.isBlank((String)raw) || ((String)raw).length()>maxLen) throw new OfferException('Niepoprawne pole: '+key);
        return ((String)raw).trim();
    }
    private static Demo_Offer__c loadOffer(String key,Boolean locking) {
        List<Demo_Offer__c> rows = Database.query('SELECT '+FIELDS+' FROM Demo_Offer__c WHERE Request_Key__c=:key LIMIT 1'+(locking?' FOR UPDATE':''));
        if (rows.isEmpty()) throw new OfferException('Nie znaleziono oferty.');
        return rows[0];
    }
    private static String digest(Object data) { return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256',Blob.valueOf(JSON.serialize(data)))); }
    private static Map<String,Object> snapshot(Id opportunityId) {
        List<Opportunity> os = [SELECT Id,Name,Description,StageName,IsClosed,AccountId,Account.Name,Account.LastModifiedDate,LastModifiedDate,Pricebook2Id FROM Opportunity WHERE Id=:opportunityId LIMIT 1];
        if (os.isEmpty() || !os[0].Name.startsWith(PREFIX)) throw new OfferException('Wybierz szansę oznaczoną EMF DEMO.');
        Opportunity o=os[0];
        if (o.IsClosed || o.AccountId==null || o.Pricebook2Id==null) throw new OfferException('Szansa musi być otwarta, mieć firmę i cennik.');
        List<OpportunityContactRole> roles=[SELECT ContactId,Contact.Name,Contact.Email,Contact.LastModifiedDate FROM OpportunityContactRole WHERE OpportunityId=:o.Id AND IsPrimary=true ORDER BY Id LIMIT 2];
        if (roles.size()!=1 || String.isBlank(roles[0].Contact.Email)) throw new OfferException('Ustaw jeden główny kontakt z adresem e-mail na szansie.');
        String productPattern='EMF_%';
        List<PricebookEntry> entries=[SELECT Id,Product2.ProductCode,Product2.Name,Product2.Description,Product2.LastModifiedDate,UnitPrice,LastModifiedDate FROM PricebookEntry WHERE Pricebook2Id=:o.Pricebook2Id AND IsActive=true AND Product2.IsActive=true AND Product2.ProductCode LIKE :productPattern ORDER BY Product2.ProductCode LIMIT 4];
        if(entries.size()!=3) throw new OfferException('Cennik demonstracyjny musi zawierać dokładnie 3 aktywne pakiety EMF_.');
        if(UserInfo.getDefaultCurrency()!='PLN') throw new OfferException('Ustaw walutę środowiska demonstracyjnego na PLN przed przygotowaniem oferty.');
        List<Object> catalog=new List<Object>();
        for(PricebookEntry p:entries) {
            Decimal minor=p.UnitPrice*100;
            if(p.UnitPrice<0 || minor!=minor.setScale(0)) throw new OfferException('Cena musi być nieujemna i mieć maksymalnie 2 miejsca dziesiętne.');
            catalog.add(new Map<String,Object>{'productCode'=>p.Product2.ProductCode,'name'=>p.Product2.Name,'description'=>p.Product2.Description,'unitMinor'=>minor.longValue(),'currency'=>'PLN','entryId'=>p.Id,'modified'=>p.LastModifiedDate,'productModified'=>p.Product2.LastModifiedDate});
        }
        OpportunityContactRole r=roles[0];
        return new Map<String,Object>{'customer'=>new Map<String,Object>{'id'=>o.AccountId,'name'=>o.Account.Name,'modified'=>o.Account.LastModifiedDate,'contactId'=>r.ContactId,'contactName'=>r.Contact.Name,'contactEmail'=>r.Contact.Email,'contactModified'=>r.Contact.LastModifiedDate},'opportunity'=>new Map<String,Object>{'id'=>o.Id,'name'=>o.Name,'description'=>o.Description,'stage'=>o.StageName,'modified'=>o.LastModifiedDate},'catalog'=>catalog};
    }
    private static Map<String,Object> prepare(Map<String,Object> b) {
        String key=required(b,'requestId',80);
        if(!Pattern.matches('^[a-zA-Z0-9_-]{8,80}$',key)) throw new OfferException('Niepoprawny requestId.');
        String execution=required(b,'executionId',80);
        String action=(String)b.get('action');
        List<Demo_Offer__c> existing=Database.query('SELECT '+FIELDS+' FROM Demo_Offer__c WHERE Request_Key__c=:key LIMIT 1 FOR UPDATE');
        Demo_Offer__c offer;
        if(existing.isEmpty()) {
            if(action=='retry') throw new OfferException('Brak zlecenia do ponowienia.');
            String instruction=required(b,'instruction',12000);
            Id oppId=(Id)required(b,'opportunityId',18);
            snapshot(oppId); // Validate before persisting a new job.
            offer=new Demo_Offer__c(Request_Key__c=key,Opportunity__c=oppId,Instruction__c=instruction,Revision__c=1,Status__c='NEW');
            Database.SaveResult sr=Database.insert(offer,false);
            if(!sr.isSuccess()) {
                if(sr.getErrors()[0].getStatusCode()==StatusCode.DUPLICATE_VALUE) return new Map<String,Object>{'httpStatus'=>409,'status'=>'PROCESSING','message'=>'Zlecenie zostało już przyjęte. Odczytaj jego stan.','requestId'=>key,'generate'=>false};
                throw new OfferException('Nie udało się zapisać zlecenia.');
            }
        } else {
            offer=existing[0];
            if(action=='prepare' && (offer.Instruction__c!=(String)b.get('instruction') || offer.Opportunity__c!=(Id)b.get('opportunityId'))) throw new OfferException('Ten identyfikator należy do innego zlecenia.');
            if(offer.Status__c=='PREPARING' && offer.Execution_Id__c==execution) {
                Map<String,Object> resumed=(Map<String,Object>)JSON.deserializeUntyped(offer.Snapshot__c);
                resumed.put('instruction',offer.Instruction__c); resumed.put('feedback',offer.Feedback__c); resumed.put('revision',offer.Revision__c); resumed.put('requestId',key); resumed.put('generate',true); return resumed;
            }
            if(offer.Status__c=='PREPARING') {
                // Explicit recovery only after a stale execution; no automatic scheduler.
                if(action!='retry' || offer.LastModifiedDate>System.now().addMinutes(-10)) return result(offer);
            } else if(offer.Status__c!='NEW' && !(action=='retry' && offer.Status__c=='FAILED')) return result(offer);
        }
        Map<String,Object> source=snapshot(offer.Opportunity__c);
        offer.Source_Hash__c=digest(source); offer.Snapshot__c=JSON.serialize(source); offer.Status__c='PREPARING'; offer.Execution_Id__c=execution; offer.Last_Error__c=null;
        update offer;
        source.put('instruction',offer.Instruction__c); source.put('feedback',offer.Feedback__c); source.put('revision',offer.Revision__c); source.put('requestId',key); source.put('generate',true);
        return source;
    }
    private static Map<String,Object> saveDraft(Map<String,Object> b) {
        Demo_Offer__c o=loadOffer(required(b,'requestId',80),true);
        if(o.Status__c!='PREPARING' || o.Execution_Id__c!=required(b,'executionId',80) || o.Revision__c!=Decimal.valueOf(String.valueOf(b.get('revision')))) return conflict(o,'Nieaktualne wykonanie przygotowania.');
        Map<String,Object> p=(Map<String,Object>)b.get('proposal');
        validateProposal(p,(Map<String,Object>)JSON.deserializeUntyped(o.Snapshot__c));
        o.Proposal__c=JSON.serialize(p);
        o.Status__c=((List<Object>)p.get('questions')).isEmpty()?'REVIEW':'NEEDS_INPUT';
        update o; return result(o);
    }
    private static void validateProposal(Map<String,Object> p,Map<String,Object> source) {
        if(p==null || p.get('currency')!='PLN' || p.get('pricing')!='net') throw new OfferException('Niepoprawna propozycja.');
        required(p,'summary',3000);
        for(String k:new List<String>{'questions','assumptions'}) {
            List<Object> values=(List<Object>)p.get(k);
            if(values==null || values.size()>8) throw new OfferException('Niepoprawne '+k);
            for(Object value:values) if(!(value instanceof String) || String.isBlank((String)value) || ((String)value).length()>700) throw new OfferException('Niepoprawna treść '+k);
        }
        Map<String,Map<String,Object>> cat=new Map<String,Map<String,Object>>();
        for(Object raw:(List<Object>)source.get('catalog')) { Map<String,Object> item=(Map<String,Object>)raw; cat.put((String)item.get('productCode'),item); }
        List<Object> lines=(List<Object>)p.get('lines');
        if(lines==null || lines.size()>3 || (lines.isEmpty() && ((List<Object>)p.get('questions')).isEmpty())) throw new OfferException('Brak pozycji lub pytań.');
        Decimal total=0; Set<String> seen=new Set<String>();
        for(Object raw:lines) {
            Map<String,Object> l=(Map<String,Object>)raw; String code=(String)l.get('productCode');
            if(!cat.containsKey(code) || seen.contains(code)) throw new OfferException('Nieznany lub powtórzony produkt.'); seen.add(code);
            Decimal q=Decimal.valueOf(String.valueOf(l.get('quantity'))), unit=Decimal.valueOf(String.valueOf(l.get('unitMinor'))), amount=Decimal.valueOf(String.valueOf(l.get('lineMinor')));
            if(q<1 || q>10 || q!=q.setScale(0) || unit!=Decimal.valueOf(String.valueOf(cat.get(code).get('unitMinor'))) || amount!=q*unit || l.get('name')!=cat.get(code).get('name')) throw new OfferException('Kalkulacja nie odpowiada cennikowi.');
            total+=amount;
        }
        if(total!=Decimal.valueOf(String.valueOf(p.get('totalMinor')))) throw new OfferException('Niepoprawna suma.');
    }
    private static Map<String,Object> decide(Map<String,Object> b) {
        Demo_Offer__c o=loadOffer(required(b,'requestId',80),true);
        Decimal revision=Decimal.valueOf(String.valueOf(b.get('revision')));
        String action=required(b,'action',20);
        if(revision!=o.Revision__c) return conflict(o,'Ta wersja jest nieaktualna.');
        if(o.Status__c=='READY' && action=='approve') return result(o);
        if(o.Status__c=='REJECTED' && action=='reject') return result(o);
        if(!new Set<String>{'REVIEW','NEEDS_INPUT'}.contains(o.Status__c)) return conflict(o,'Oferta nie oczekuje na decyzję.');
        if(action=='reject') { o.Status__c='REJECTED'; o.Feedback__c=(String)b.get('feedback'); update o; return result(o); }
        if(action=='revise') {
            String feedback=required(b,'feedback',6000);
            if(o.Revision__c>=10) throw new OfferException('Limit 10 wersji demonstracyjnych.');
            o.Revision__c+=1; o.Status__c='NEW'; o.Feedback__c=String.isBlank(o.Feedback__c)?feedback:o.Feedback__c+'\n'+feedback;
            if(o.Feedback__c.length()>12000) throw new OfferException('Zbyt długie uwagi.');
            o.Proposal__c=null; update o;
            Map<String,Object> out=result(o); out.put('regenerate',true); return out;
        }
        if(action!='approve') throw new OfferException('Nieznana decyzja.');
        if(o.Status__c!='REVIEW') return conflict(o,'Najpierw uzupełnij brakujące informacje.');
        if(o.Source_Hash__c!=digest(snapshot(o.Opportunity__c))) return conflict(o,'Dane CRM lub cennik uległy zmianie. Przygotuj nową wersję.');
        Map<String,Object> p=(Map<String,Object>)JSON.deserializeUntyped(o.Proposal__c);
        Map<String,Object> context=(Map<String,Object>)JSON.deserializeUntyped(o.Snapshot__c);
        validateProposal(p,context);
        // Both records commit in ONE transaction while the offer row is locked.
        ContentVersion cv=new ContentVersion(Title='Oferta '+o.Name+' v'+o.Revision__c,PathOnClient='oferta-'+o.Name+'-v'+o.Revision__c+'.pdf',VersionData=Blob.toPdf(renderDocument(context,p,o)),FirstPublishLocationId=o.Opportunity__c);
        insert cv;
        cv=[SELECT ContentDocumentId FROM ContentVersion WHERE Id=:cv.Id];
        insert new ContentDocumentLink(ContentDocumentId=cv.ContentDocumentId,LinkedEntityId=o.Id,ShareType='V');
        o.Document_Id__c=String.valueOf(cv.ContentDocumentId); o.Status__c='READY'; o.Approved_At__c=System.now(); o.Approved_By__c=UserInfo.getUserId(); update o;
        return result(o);
    }
    private static Map<String,Object> recordError(Map<String,Object> b) {
        String exec=required(b,'executionId',80);
        List<Demo_Offer__c> offers=Database.query('SELECT '+FIELDS+' FROM Demo_Offer__c WHERE Execution_Id__c=:exec LIMIT 1 FOR UPDATE');
        if(offers.isEmpty()) return new Map<String,Object>{'recorded'=>false,'message'=>'Brak rekordu dla wykonania; sprawdź log n8n.'};
        Demo_Offer__c o=offers[0];
        if(o.Status__c=='PREPARING') { o.Status__c='FAILED'; o.Last_Error__c=required(b,'message',2000); update o; }
        return result(o);
    }
    private static Map<String,Object> conflict(Demo_Offer__c o,String message) { Map<String,Object> out=result(o); out.put('httpStatus',409); out.put('code','CONFLICT'); out.put('message',message); return out; }
    private static Map<String,Object> result(Demo_Offer__c o) {
        // Link directly to the UI domain; avoid the API-domain redirect when opened from n8n.
        String base=URL.getOrgDomainUrl().toExternalForm().replace('.my.salesforce.com','.lightning.force.com');
        Map<String,Object> out=new Map<String,Object>{'requestId'=>o.Request_Key__c,'revision'=>o.Revision__c,'status'=>o.Status__c,'generate'=>false,'recordUrl'=>base+'/lightning/r/Demo_Offer__c/'+o.Id+'/view'};
        if(o.Proposal__c!=null) out.put('proposal',JSON.deserializeUntyped(o.Proposal__c));
        if(o.Document_Id__c!=null) out.put('documentUrl',base+'/lightning/r/ContentDocument/'+o.Document_Id__c+'/view');
        if(o.Last_Error__c!=null) out.put('message','Przygotowanie przerwane. Można ponowić zlecenie.');
        return out;
    }
    private static String h(Object value) { return value==null?'':String.valueOf(value).escapeHtml4(); }
    private static String cash(Object minor) {
        String raw=(Decimal.valueOf(String.valueOf(minor))/100).setScale(2).toPlainString();
        List<String> parts=raw.split('\\.'); String whole=parts[0], grouped='';
        while(whole.length()>3) { grouped=' '+whole.substring(whole.length()-3)+grouped; whole=whole.substring(0,whole.length()-3); }
        return whole+grouped+','+parts[1]+' PLN';
    }
    @TestVisible private static String renderDocument(Map<String,Object> c,Map<String,Object> p,Demo_Offer__c o) {
        Map<String,Object> customer=(Map<String,Object>)c.get('customer');
        Date today=Date.today();
        String issued=String.valueOf(today.day()).leftPad(2,'0')+'.'+String.valueOf(today.month()).leftPad(2,'0')+'.'+today.year();
        String html='<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" lang="pl"><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />'+
            '<title>Oferta '+h(o.Name)+'</title><style type="text/css">'+
            '@page { size: A4; margin: 17mm 17mm 20mm; @bottom-left { content: "STUDIO AUTOMATYZACJI / DEMO"; font-family: sans-serif; font-size: 7pt; color: #74857e; } @bottom-right { content: "Strona " counter(page) " / " counter(pages); font-family: sans-serif; font-size: 7pt; color: #74857e; } }'+
            'body { font-family: "Arial Unicode MS"; font-size: 10pt; line-height: 1.55; color: #203831; margin: 0; padding: 0; }'+
            'table { width: 100%; border-collapse: collapse; table-layout: fixed; } td, th { vertical-align: top; overflow-wrap: break-word; word-wrap: break-word; }'+
            '.masthead { margin-bottom: 22pt; border-bottom: 2pt solid #1c7663; } .masthead td { padding: 0 0 11pt; }'+
            '.brand { font-family: sans-serif; font-size: 10pt; font-weight: bold; letter-spacing: 1.3pt; color: #1c7663; } .reference { text-align: right; font-size: 9pt; color: #566f65; }'+
            'h1 { font-family: sans-serif; font-size: 29pt; font-weight: bold; line-height: 1.1; color: #153f33; margin: 0 0 9pt; }'+
            '.lead { font-size: 10pt; color: #65796e; margin: 0 0 21pt; }'+
            '.meta { margin: 0 0 22pt; } .meta td { background: #f1f5ef; padding: 13pt 15pt; } .meta .right { border-left: 5pt solid #fff; }'+
            '.label { font-family: sans-serif; font-size: 7pt; letter-spacing: 1.1pt; color: #6c7f71; margin: 0 0 5pt; } .customer { font-size: 12pt; color: #153f33; margin: 0 0 5pt; } .detail { font-size: 9pt; color: #52685d; }'+
            'h2 { font-size: 12pt; color: #1c7663; margin: 18pt 0 9pt; page-break-after: avoid; } .index { font-family: sans-serif; font-size: 9pt; color: #91a89b; }'+
            'p { margin: 0 0 9pt; orphans: 3; widows: 3; } .scope { white-space: pre-line; }'+
            '.pricing thead { display: table-header-group; } .pricing th { background: #194f3f; color: #fff; font-size: 8pt; font-weight: normal; padding: 10pt 8pt; }'+
            '.pricing td { padding: 11pt 8pt; border-bottom: 0.6pt solid #dce6dc; font-size: 9pt; } .pricing tr { page-break-inside: avoid; } .number { text-align: right; } .center { text-align: center; } .code { font-family: sans-serif; font-size: 7pt; color: #7c9084; margin-top: 3pt; }'+
            '.total { margin: 14pt 0 21pt; page-break-inside: avoid; } .total td { padding: 13pt 14pt; background: #edf3e7; } .total .amount { text-align: right; font-size: 20pt; color: #153f33; } .total .caption { padding-top: 20pt; font-size: 10pt; }'+
            '.assumption { margin: 0 0 7pt; padding: 0 0 0 12pt; border-left: 2pt solid #d3e1d0; page-break-inside: avoid; }'+
            '.terms { margin-top: 23pt; padding: 12pt 14pt; background: #f8f5ec; font-size: 8pt; line-height: 1.65; page-break-inside: avoid; } .terms p { margin: 0; } .terms .label { margin-bottom: 5pt; }'+
            '</style></head><body>'+
            '<table class="masthead"><tr><td style="width:62%"><span class="brand">STUDIO AUTOMATYZACJI</span><br/><span class="detail">Propozycja usprawnienia procesu</span></td><td class="reference">'+h(o.Name)+'<br/>Wersja '+h(o.Revision__c)+'</td></tr></table>'+
            '<h1>Oferta automatyzacji</h1><p class="lead">Zakres przygotowany na podstawie potrzeb klienta i cennika usług.</p>'+
            '<table class="meta"><tr><td style="width:62%"><p class="label">PRZYGOTOWANO DLA</p><p class="customer">'+h(customer.get('name'))+'</p><span class="detail">'+h(customer.get('contactName'))+'</span></td>'+
            '<td class="right"><p class="label">INFORMACJE O OFERCIE</p><span class="detail">Data: '+issued+'<br/>Waluta: PLN<br/>Wycena: kwoty netto</span></td></tr></table>'+
            '<h2><span class="index">01 / </span>Proponowany zakres</h2><p class="scope">'+h(p.get('summary'))+'</p>'+
            '<h2><span class="index">02 / </span>Usługi i wycena</h2><table class="pricing"><thead><tr><th style="width:44%">Usługa</th><th class="center" style="width:10%">Ilość</th><th class="number" style="width:23%">Cena netto</th><th class="number" style="width:23%">Wartość netto</th></tr></thead><tbody>';
        for(Object raw:(List<Object>)p.get('lines')) {
            Map<String,Object> l=(Map<String,Object>)raw;
            html+='<tr><td>'+h(l.get('name'))+'<div class="code">'+h(l.get('productCode'))+'</div></td><td class="center">'+h(l.get('quantity'))+'</td><td class="number">'+cash(l.get('unitMinor'))+'</td><td class="number">'+cash(l.get('lineMinor'))+'</td></tr>';
        }
        html+='</tbody></table><table class="total"><tr><td class="caption" style="width:43%">Razem netto</td><td class="amount">'+cash(p.get('totalMinor'))+'</td></tr></table>'+
            '<h2><span class="index">03 / </span>Założenia do realizacji</h2>';
        List<Object> assumptions=(List<Object>)p.get('assumptions');
        if(assumptions.isEmpty()) html+='<p class="detail">Brak dodatkowych założeń.</p>';
        for(Object a:assumptions) html+='<p class="assumption">'+h(a)+'</p>';
        return html+'<div class="terms"><p class="label">INFORMACJE DEMONSTRACYJNE</p><p>Oferta demonstracyjna - fikcyjne dane i cennik. Termin wdrożenia oraz pozostałe warunki wymagają osobnego uzgodnienia. Dokument prezentuje wycenę netto w PLN.</p></div></body></html>';
    }
}
