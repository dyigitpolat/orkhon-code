import Foundation
@main struct AssociationPolicyTests {
 static func main() {
  var count=0
  func check(_ title:String,_ result:Bool) {count+=1;if !result {fputs("FAIL: \(title)\n",stderr);exit(1)}}
  for ext in ["pot","vhd","p","html","htm","shtml","xhtml","svg","ts","mts","m2ts","ps","plist","tpl","pxd","url","msg","frm","idx","as","ig","pdf","doc","rtf","numbers","xlsx","xls","logarchive"] {
   check("Excluded format \(ext)",!AssociationPolicy.eligible(extensions:[ext],isSource:true))
  }
  for ext in AssociationPolicy.sourceExtensions {
   check("Reviewed text format available: \(ext)",AssociationPolicy.eligible(extensions:[ext],isSource:true))
  }
  for ext in ["txt","text","json","toml","yaml","yml","jsonc","json5","rs","go","md","cpp","hpp","tsx","css","xml","ini","sql","csv","tsv","log"] {
   check("Essential extension included: \(ext)",AssociationPolicy.sourceExtensions.contains(ext))
  }
  check("Non-text rejected even with a reviewed suffix",!AssociationPolicy.eligible(extensions:["log"],isSource:false))
  check("Shared ambiguous alias rejected",!AssociationPolicy.eligible(extensions:["swift","ts"],isSource:true))
  check("CSV sharing a binary alias rejected",!AssociationPolicy.eligible(extensions:["csv","xls"],isSource:true))
  check("Empty aliases rejected",!AssociationPolicy.eligible(extensions:[],isSource:true))
  check("Case-insensitive extensions",AssociationPolicy.eligible(extensions:["CSV","TSV"],isSource:true))
  for aliases in [["md"],["hpp","hh","hp","hxx","h++","ipp"],["js","mjs","jscript","javascript"],["java","jav"],["rb","rbw"],["txt","text"],["log"],["csv"],["tsv"],["cpp","cp","cc"]] {
   check("Recognized safe alias group",AssociationPolicy.eligible(extensions:aliases,isSource:true))
   check("Eligible formats have no lock reason",AssociationPolicy.ineligibilityReason(extensions:aliases,isSource:true)==nil)
  }
  print("\(count) association policy checks passed")
 }
}
