import 'bank_launcher.dart';
import 'domain.dart';

const bankNames = {'822': '中國信託', '812': '台新銀行', '700': '中華郵政'};

String bankLabel(String code) =>
    bankNames.containsKey(code) ? '$code ${bankNames[code]}' : '銀行代碼 $code';

const bankApps = [
  BankAppChoice(id: 'com.chinatrust.mobilebank', label: '中國信託行動銀行'),
  BankAppChoice(id: 'tw.com.taishinbank.mobile', label: '台新行動銀行'),
  BankAppChoice(id: 'tw.gov.post.mpost', label: '行動郵局'),
];

Future<void> copyAccount(String number) => BankLauncher.copyAccount(number);
