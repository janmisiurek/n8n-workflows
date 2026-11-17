// Only creates/reuses explicitly named fictional portfolio fixtures. No outbound emails.
Account a;
List<Account> accounts=[SELECT Id FROM Account WHERE Name='EMF DEMO - Latarnia Studio' LIMIT 2];
System.assert(accounts.size()<2,'Ambiguous demo accounts');
if(accounts.isEmpty()){a=new Account(Name='EMF DEMO - Latarnia Studio',Description='Fikcyjna firma do demonstracji portfolio.');insert a;}else a=accounts[0];
List<Contact> contacts=[SELECT Id FROM Contact WHERE AccountId=:a.Id AND Email='anna.demo@example.com' LIMIT 2];
System.assert(contacts.size()<2,'Ambiguous demo contacts');
Contact c;
if(contacts.isEmpty()){c=new Contact(AccountId=a.Id,FirstName='Anna',LastName='Demo',Email='anna.demo@example.com');insert c;}else c=contacts[0];
Pricebook2 pb=[SELECT Id,IsActive FROM Pricebook2 WHERE IsStandard=true LIMIT 1];
if(!pb.IsActive){pb.IsActive=true;update pb;}
List<String> codes=new List<String>{'EMF_START','EMF_TEAM','EMF_SCALE'};
List<String> names=new List<String>{'Automatyzacja jednego procesu','Automatyzacje zespołu sprzedaży','Integracja kilku procesów CRM'};
List<String> descriptions=new List<String>{'Jedna skrzynka lub formularz, zapis zapytań w CRM i zadania dla handlowca.','Dwa procesy sprzedażowe: zapytania oraz przygotowanie ofert z danych CRM.','Trzy procesy obejmujące CRM, pocztę i raportowanie.'};
List<Decimal> prices=new List<Decimal>{3000,6000,10000};
for(Integer i=0;i<codes.size();i++){
 String code=codes[i];List<Product2> found=[SELECT Id FROM Product2 WHERE ProductCode=:code LIMIT 2];System.assert(found.size()<2,'Duplicate product code');
 Product2 p;
 if(found.isEmpty()){p=new Product2(ProductCode=code,Name=names[i],Description=descriptions[i],IsActive=true);insert p;}else p=found[0];
 if([SELECT Count() FROM PricebookEntry WHERE Pricebook2Id=:pb.Id AND Product2Id=:p.Id]==0)insert new PricebookEntry(Pricebook2Id=pb.Id,Product2Id=p.Id,UnitPrice=prices[i],IsActive=true);
}
List<Opportunity> opportunities=[SELECT Id FROM Opportunity WHERE Name='EMF DEMO - Obsługa zapytań' LIMIT 2];System.assert(opportunities.size()<2,'Ambiguous opportunities');
Opportunity o;
if(opportunities.isEmpty()){o=new Opportunity(Name='EMF DEMO - Obsługa zapytań',AccountId=a.Id,StageName='Prospecting',CloseDate=Date.today().addDays(30),Pricebook2Id=pb.Id,Description='Klient otrzymuje około 200 zapytań miesięcznie. Pracuje w Gmail i Salesforce. Potrzebuje rejestracji zapytań oraz zadań dla handlowca.');insert o;}else o=opportunities[0];
if([SELECT Count() FROM OpportunityContactRole WHERE OpportunityId=:o.Id AND IsPrimary=true]==0)insert new OpportunityContactRole(OpportunityId=o.Id,ContactId=c.Id,IsPrimary=true,Role='Decision Maker');
System.debug('EMF_DEMO_OPPORTUNITY_ID='+o.Id);
System.debug('ORG_DEFAULT_CURRENCY='+UserInfo.getDefaultCurrency());
