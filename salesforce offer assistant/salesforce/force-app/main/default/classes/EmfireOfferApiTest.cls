@IsTest private class EmfireOfferApiTest {
    @TestSetup static void setup() {
        PermissionSet ps=[SELECT Id FROM PermissionSet WHERE Name='Emfire_Offer_Demo' LIMIT 1];
        Id uid=UserInfo.getUserId();
        if([SELECT Count() FROM PermissionSetAssignment WHERE AssigneeId=:uid AND PermissionSetId=:ps.Id]==0) insert new PermissionSetAssignment(AssigneeId=uid,PermissionSetId=ps.Id);
        System.runAs(new User(Id=uid)) {
            Account a=new Account(Name='EMF DEMO - Test Company'); insert a;
            Contact c=new Contact(AccountId=a.Id,LastName='Demo',Email='demo@example.com'); insert c;
            Id pb=Test.getStandardPricebookId();
            update new Pricebook2(Id=pb,IsActive=true);
            List<Product2> products=new List<Product2>();
            for(String code:new List<String>{'EMF_START','EMF_TEAM','EMF_SCALE'}) products.add(new Product2(Name=code,ProductCode=code,Description='Fikcyjny pakiet demonstracyjny',IsActive=true));
            insert products;
            List<PricebookEntry> prices=new List<PricebookEntry>();
            for(Product2 p:products) prices.add(new PricebookEntry(Product2Id=p.Id,Pricebook2Id=pb,UnitPrice=3000,IsActive=true));
            insert prices;
            Opportunity o=new Opportunity(Name='EMF DEMO - Test Opportunity',AccountId=a.Id,StageName='Prospecting',CloseDate=Date.today().addDays(30),Pricebook2Id=pb); insert o;
            insert new OpportunityContactRole(OpportunityId=o.Id,ContactId=c.Id,IsPrimary=true,Role='Decision Maker');
        }
    }
    private static Map<String,Object> call(String endpoint,Map<String,Object> body) {
        RestRequest req=new RestRequest();req.requestURI='/services/apexrest/emfire-offers/v1/'+endpoint;req.httpMethod='POST';req.requestBody=Blob.valueOf(JSON.serialize(body));
        RestContext.request=req; RestContext.response=new RestResponse(); EmfireOfferApi.postRequest();
        return (Map<String,Object>)JSON.deserializeUntyped(RestContext.response.responseBody.toString());
    }
    private static Map<String,Object> prepare(String key) {
        Opportunity o=[SELECT Id FROM Opportunity WHERE Name='EMF DEMO - Test Opportunity' LIMIT 1];
        return call('prepare',new Map<String,Object>{'action'=>'prepare','requestId'=>key,'opportunityId'=>o.Id,'instruction'=>'Obsługa zapytań sprzedażowych','executionId'=>'exec-'+key});
    }
    private static Map<String,Object> draft(String key,Boolean questions) {
        Map<String,Object> c=prepare(key);
        System.assertEquals(true,c.get('generate'),JSON.serialize(c));
        Map<String,Object> p=(Map<String,Object>)((List<Object>)c.get('catalog'))[0];
        Decimal unit=Decimal.valueOf(String.valueOf(p.get('unitMinor')));
        Map<String,Object> proposal=new Map<String,Object>{'summary'=>'Automatyzacja skrzynki zapytań','lines'=>new List<Object>{new Map<String,Object>{'productCode'=>p.get('productCode'),'name'=>p.get('name'),'quantity'=>1,'unitMinor'=>unit,'lineMinor'=>unit}},'questions'=>questions?new List<String>{'Która skrzynka?'}:new List<String>(),'assumptions'=>new List<String>{'Jedna skrzynka'},'totalMinor'=>unit,'currency'=>'PLN','pricing'=>'net','revision'=>1};
        return call('draft',new Map<String,Object>{'requestId'=>key,'executionId'=>'exec-'+key,'revision'=>1,'proposal'=>proposal});
    }
    @IsTest static void happyPathAndRepeatedApproval() {
        Map<String,Object> d=draft('request-happy',false);System.assertEquals('REVIEW',d.get('status'));
        Map<String,Object> b=new Map<String,Object>{'requestId'=>'request-happy','revision'=>1,'action'=>'approve'};
        Map<String,Object> r=call('decision',b);System.assertEquals('READY',r.get('status'),JSON.serialize(r));
        Map<String,Object> again=call('decision',b);System.assertEquals(r.get('documentUrl'),again.get('documentUrl'));
        System.assertEquals(1,[SELECT Count() FROM ContentVersion WHERE Title LIKE 'Oferta OFF-%']);
        ContentVersion cv=[SELECT FileExtension,FileType,VersionData FROM ContentVersion WHERE Title LIKE 'Oferta OFF-%' LIMIT 1];
        System.assertEquals('pdf',cv.FileExtension); System.assertEquals('PDF',cv.FileType);
        System.assert(EncodingUtil.convertToHex(cv.VersionData).startsWith('255044462d'),'Expected actual PDF bytes');
        System.assert(String.valueOf(r.get('documentUrl')).contains('.lightning.force.com/lightning/r/ContentDocument/'),'Direct Lightning UI URL');
    }
    @IsTest static void missingDataPreventsApproval() {
        System.assertEquals('NEEDS_INPUT',draft('request-questions',true).get('status'));
        System.assertEquals(409,call('decision',new Map<String,Object>{'requestId'=>'request-questions','revision'=>1,'action'=>'approve'}).get('httpStatus'));
        System.assertEquals(0,[SELECT Count() FROM ContentVersion]);
    }
    @IsTest static void staleRevisionRejected() {
        draft('request-revise',false);
        Map<String,Object> r=call('decision',new Map<String,Object>{'requestId'=>'request-revise','revision'=>1,'action'=>'revise','feedback'=>'Dodaj zakres zespołowy'});
        System.assertEquals('NEW',r.get('status'));System.assertEquals(2,Decimal.valueOf(String.valueOf(r.get('revision'))));
        System.assertEquals(409,call('decision',new Map<String,Object>{'requestId'=>'request-revise','revision'=>1,'action'=>'approve'}).get('httpStatus'));
    }
    @IsTest static void changedPriceRequiresNewDraft() {
        draft('request-price',false);
        PricebookEntry p=[SELECT Id,UnitPrice FROM PricebookEntry LIMIT 1];p.UnitPrice+=1;update p;
        Map<String,Object> r=call('decision',new Map<String,Object>{'requestId'=>'request-price','revision'=>1,'action'=>'approve'});
        System.assertEquals(409,r.get('httpStatus'));System.assertEquals(0,[SELECT Count() FROM ContentVersion]);
    }
    @IsTest static void rejectionIsTerminal() {
        draft('request-reject',false);
        System.assertEquals('REJECTED',call('decision',new Map<String,Object>{'requestId'=>'request-reject','revision'=>1,'action'=>'reject'}).get('status'));
        System.assertEquals(409,call('decision',new Map<String,Object>{'requestId'=>'request-reject','revision'=>1,'action'=>'approve'}).get('httpStatus'));
    }
    @IsTest static void executionOwnershipAndFailureRecovery() {
        prepare('request-recover');
        Map<String,Object> r=call('prepare',new Map<String,Object>{'requestId'=>'request-recover','action'=>'retry','executionId'=>'other'});
        System.assertEquals(false,r.get('generate'));
        call('error',new Map<String,Object>{'executionId'=>'exec-request-recover','message'=>'Simulated model outage'});
        System.assertEquals('FAILED',[SELECT Status__c FROM Demo_Offer__c WHERE Request_Key__c='request-recover'].Status__c);
        r=call('prepare',new Map<String,Object>{'requestId'=>'request-recover','action'=>'retry','executionId'=>'recovery'});
        System.assertEquals(true,r.get('generate'));
    }
    @IsTest static void serverRejectsTamperedPrices() {
        Map<String,Object> c=prepare('request-tamper');Map<String,Object> p=(Map<String,Object>)((List<Object>)c.get('catalog'))[0];
        Map<String,Object> proposal=new Map<String,Object>{'summary'=>'Test','lines'=>new List<Object>{new Map<String,Object>{'productCode'=>p.get('productCode'),'name'=>p.get('name'),'quantity'=>1,'unitMinor'=>1,'lineMinor'=>1}},'questions'=>new List<String>(),'assumptions'=>new List<String>(),'totalMinor'=>1,'currency'=>'PLN','pricing'=>'net'};
        Map<String,Object> r=call('draft',new Map<String,Object>{'requestId'=>'request-tamper','revision'=>1,'executionId'=>'exec-request-tamper','proposal'=>proposal});System.assertEquals('VALIDATION',r.get('code'));
    }
    @IsTest static void existingRequestDoesNotRegenerateAfterDraft() {
        draft('request-repeat',false);
        Map<String,Object> r=prepare('request-repeat');System.assertEquals(false,r.get('generate'));System.assertEquals('REVIEW',r.get('status'));
        System.assertEquals(1,[SELECT Count() FROM Demo_Offer__c WHERE Request_Key__c='request-repeat']);
    }
    @IsTest static void pdfTemplateEscapesContentAndFormatsPolishMoney() {
        Map<String,Object> c=new Map<String,Object>{'customer'=>new Map<String,Object>{'name'=>'Żółć <script>alert(1)</script>','contactName'=>'Łukasz & Anna'}};
        Map<String,Object> p=new Map<String,Object>{'summary'=>'Zażółć gęślą jaźń <img src=x />','lines'=>new List<Object>{new Map<String,Object>{'name'=>'Usługa','productCode'=>'EMF_START','quantity'=>1,'unitMinor'=>123456789,'lineMinor'=>123456789}},'assumptions'=>new List<Object>{'Ścieżka wdrożenia & uzgodnienia'},'totalMinor'=>123456789};
        prepare('request-layout');
        Demo_Offer__c o=[SELECT Name,Revision__c FROM Demo_Offer__c WHERE Request_Key__c='request-layout' LIMIT 1];
        String rendered=EmfireOfferApi.renderDocument(c,p,o);
        System.assert(rendered.contains('1 234 567,89 PLN'));
        System.assert(rendered.contains('Arial Unicode MS'));
        System.assert(!rendered.contains('<script>') && !rendered.contains('<img src=x'));
        System.assert(rendered.contains('&lt;script&gt;') && rendered.contains('&amp;'));
        System.assert(rendered.contains('page-break-inside: avoid'));
    }
}
