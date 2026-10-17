#property copyright "13Pat Safe VPS FIXED - No Warnings"
#property version   "3.11"
#property strict

#include <Trade\Trade.mqh>

input long   MagicNumber            = 123456;
input double RiskPercent            = 5.0;
input int    ATR_Period             = 14;
input double ATR_StopMultiplier     = 0.9;
input double RewardRatio            = 1.8;
input int    MaxSpreadPoints        = 300;
input int    TradingStartHour       = 0;
input int    TradingEndHour         = 23;
input int    ExchangeTimezoneOffset = 0;
input bool   UseExchangeTimezone    = false;
input int    ADX_Period             = 14;
input int    EMA_Fast               = 50;
input int    EMA_Slow               = 200;
input int    RSI_Period             = 14;
input double VolMultiplier          = 1.2;
input double VolMultiplierDonchian  = 1.5;
input double MinMarginLevelPercent  = 200.0;
input double MaxDailyLossPercent    = 5.0;
input int    FridayCloseHour        = 21;
input bool   EnablePushNotifications= true;
input bool   EnableEmailAlerts      = false;
input int    MaxOpenPositionsPerMagic = 1;

CTrade   trade;
int      atr_handle=INVALID_HANDLE, adx_handle=INVALID_HANDLE, ema50_handle=INVALID_HANDLE, ema200_handle=INVALID_HANDLE, rsi_handle=INVALID_HANDLE;
datetime lastBarTime=0;
bool     isInitialized=false;
datetime lastDisconnectAlertTime=0;
datetime circuitBreakerDay=0;
bool     circuitBreakerActive=false;
datetime lastDailyResetDay=0;

bool IsNewBar();
bool HasOpenPositionForMagic();
bool HasPendingOrderForMagic();
bool IsSpreadOK();
bool IsTradingSession();
bool IsWeekendGuardOK();
bool IsTradeServerConnected();
bool IsMarginOK(double lots, ENUM_ORDER_TYPE orderType, double price);
bool IsDailyLossCircuitBreakerOK();
bool IsDuplicateGuardOK();
double CalculateLots(double stopDistancePoints);
bool OpenLong(double atrValue);
bool OpenShort(double atrValue);
void LogTradeOpen(ulong ticket, string symbol, string direction, double lots, double sl, double tp, long spreadPoints, datetime time);
void LogTradeClose(ulong ticket, string symbol, string direction, double lots, double profit, datetime time);
void SendSafetyAlert(string subject, string message);
void HandleTradeError(string context);
int GetExchangeHour();

bool IsAscTriangle(int shift);
bool IsDescTriangle(int shift);
bool IsBullEngulfEMA50(int shift);
bool IsBearEngulfEMA50(int shift);
bool IsInsideBarBO(int shift);
bool IsInsideBarBD(int shift);
bool IsBullFlag(int shift);
bool IsBearFlag(int shift);
bool IsDoubleBottom(int shift);
bool IsRectangleLong(int shift);
bool IsRectangleShort(int shift);
bool IsDonchianBOLong(int shift);
bool IsDonchianBDShort(int shift);

int OnInit()
{
   if(RiskPercent<=0 || RiskPercent>10) return(INIT_PARAMETERS_INCORRECT);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   atr_handle=iATR(_Symbol,_Period,ATR_Period);
   adx_handle=iADX(_Symbol,_Period,ADX_Period);
   ema50_handle=iMA(_Symbol,_Period,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   ema200_handle=iMA(_Symbol,_Period,EMA_Slow,0,MODE_EMA,PRICE_CLOSE);
   rsi_handle=iRSI(_Symbol,_Period,RSI_Period,PRICE_CLOSE);
   if(atr_handle==INVALID_HANDLE || adx_handle==INVALID_HANDLE || ema50_handle==INVALID_HANDLE || ema200_handle==INVALID_HANDLE || rsi_handle==INVALID_HANDLE)
      return(INIT_FAILED);

   datetime curBarTime[1];
   if(CopyTime(_Symbol,_Period,0,1,curBarTime)>0)
      lastBarTime=curBarTime[0];
   else
      lastBarTime=0;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   datetime todayMidnight=StructToTime(dt) - (datetime)dt.hour*3600 - (datetime)dt.min*60 - (datetime)dt.sec;
   lastDailyResetDay=todayMidnight;

   datetime from=todayMidnight;
   datetime to=TimeCurrent();
   if(HistorySelect(from,to))
   {
      double netPnL=0.0;
      int totalDeals=HistoryDealsTotal();
      for(int i=totalDeals-1;i>=0;i--)
      {
         ulong dealTicket=HistoryDealGetTicket(i);
         if(dealTicket==0) continue;
         long magic=(long)HistoryDealGetInteger(dealTicket,DEAL_MAGIC);
         if(magic!=MagicNumber) continue;
         string sym=HistoryDealGetString(dealTicket,DEAL_SYMBOL);
         if(sym!=_Symbol) continue;
         long entryType=(long)HistoryDealGetInteger(dealTicket,DEAL_ENTRY);
         if(entryType!=DEAL_ENTRY_OUT && entryType!=DEAL_ENTRY_OUT_BY) continue;
         double profit=HistoryDealGetDouble(dealTicket,DEAL_PROFIT);
         double swap=HistoryDealGetDouble(dealTicket,DEAL_SWAP);
         double comm=HistoryDealGetDouble(dealTicket,DEAL_COMMISSION);
         netPnL+=profit+swap+comm;
      }
      double balance=AccountInfoDouble(ACCOUNT_BALANCE);
      double threshold=-balance*(MaxDailyLossPercent/100.0);
      if(netPnL < threshold)
      {
         circuitBreakerActive=true;
         circuitBreakerDay=todayMidnight;
      }
   }

   isInitialized=true;
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(atr_handle!=INVALID_HANDLE) IndicatorRelease(atr_handle);
   if(adx_handle!=INVALID_HANDLE) IndicatorRelease(adx_handle);
   if(ema50_handle!=INVALID_HANDLE) IndicatorRelease(ema50_handle);
   if(ema200_handle!=INVALID_HANDLE) IndicatorRelease(ema200_handle);
   if(rsi_handle!=INVALID_HANDLE) IndicatorRelease(rsi_handle);
   atr_handle=adx_handle=ema50_handle=ema200_handle=rsi_handle=INVALID_HANDLE;
   isInitialized=false;
}

void OnTick()
{
   if(!isInitialized) return;
   if(!IsTradeServerConnected())
   {
      if((TimeCurrent()-lastDisconnectAlertTime) > 300)
      {
         string msg=StringFormat("Disconnected! No trades Magic %d Time=%s",MagicNumber,TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES));
         Print("RECONNECT: ",msg);
         SendSafetyAlert("MT5 Disconnected", msg);
         lastDisconnectAlertTime=TimeCurrent();
      }
      return;
   }
   if(!IsNewBar()) return;
   if(!IsWeekendGuardOK()) return;
   if(!IsDailyLossCircuitBreakerOK()) return;
   if(!IsSpreadOK()) return;
   if(!IsTradingSession()) return;
   if(!IsDuplicateGuardOK()) return;

   int shift=1;
   double atrBuf[1], adxBuf[1], ema50Buf[1], ema200Buf[1], rsiBuf[1];
   if(CopyBuffer(atr_handle,0,shift,1,atrBuf)<=0) return;
   if(CopyBuffer(adx_handle,0,shift,1,adxBuf)<=0) return;
   if(CopyBuffer(ema50_handle,0,shift,1,ema50Buf)<=0) return;
   if(CopyBuffer(ema200_handle,0,shift,1,ema200Buf)<=0) return;
   if(CopyBuffer(rsi_handle,0,shift,1,rsiBuf)<=0) return;

   double close1[1]; if(CopyClose(_Symbol,_Period,shift,1,close1)<=0) return;
   if(close1[0]==0.0) return;

   long vol1[1]; if(CopyTickVolume(_Symbol,_Period,shift,1,vol1)<=0) return;
   long volArr[20]; if(CopyTickVolume(_Symbol,_Period,shift+1,20,volArr)<=0) return;
   double volAvg20=0.0; for(int i=0;i<20;i++) volAvg20+=(double)volArr[i]; volAvg20/=20.0;
   bool volOK = ((double)vol1[0] > VolMultiplier*volAvg20);
   bool volOKDonchian = ((double)vol1[0] > VolMultiplierDonchian*volAvg20);

   bool buyTrend = (close1[0] > ema200Buf[0] && close1[0] > ema50Buf[0] && ema50Buf[0] > ema200Buf[0]);
   bool buyMomentum = (adxBuf[0] > 12.0 && rsiBuf[0] > 50.0);
   bool buyPattern=false;
   if(volOK)
   {
      bool isXAUorXAG = (StringFind(_Symbol,"XAU")>=0 || StringFind(_Symbol,"GOLD")>=0 || StringFind(_Symbol,"XAG")>=0);
      if(!isXAUorXAG && IsAscTriangle(shift)) buyPattern=true;
      if(IsBullEngulfEMA50(shift)) buyPattern=true;
      if(IsInsideBarBO(shift)) buyPattern=true;
      if(IsBullFlag(shift)) buyPattern=true;
      if(IsDoubleBottom(shift)) buyPattern=true;
      if(IsRectangleLong(shift)) buyPattern=true;
      if(volOKDonchian && IsDonchianBOLong(shift)) buyPattern=true;
   }
   if(buyTrend && buyMomentum && buyPattern){ OpenLong(atrBuf[0]); return; }

   bool sellTrend = (close1[0] < ema200Buf[0] && close1[0] < ema50Buf[0] && ema50Buf[0] < ema200Buf[0]);
   bool sellMomentum = (adxBuf[0] > 12.0 && rsiBuf[0] < 50.0);
   bool sellPattern=false;
   if(volOK)
   {
      if(IsDescTriangle(shift)) sellPattern=true;
      if(IsBearEngulfEMA50(shift)) sellPattern=true;
      if(IsInsideBarBD(shift)) sellPattern=true;
      if(IsBearFlag(shift)) sellPattern=true;
      if(IsRectangleShort(shift)) sellPattern=true;
      if(volOKDonchian && IsDonchianBDShort(shift)) sellPattern=true;
   }
   if(sellTrend && sellMomentum && sellPattern){ OpenShort(atrBuf[0]); return; }
}

int GetExchangeHour()
{
   if(!UseExchangeTimezone)
   {
      MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); return dt.hour;
   }
   MqlDateTime gmt; TimeToStruct(TimeGMT(),gmt);
   int exchHour = gmt.hour + ExchangeTimezoneOffset;
   while(exchHour<0) exchHour+=24;
   while(exchHour>=24) exchHour-=24;
   return exchHour;
}

bool IsTradingSession()
{
   int hour=GetExchangeHour();
   if(TradingStartHour <= TradingEndHour) return (hour>=TradingStartHour && hour<=TradingEndHour);
   return (hour>=TradingStartHour || hour<=TradingEndHour);
}

bool IsWeekendGuardOK()
{
   MqlDateTime dt;
   if(UseExchangeTimezone)
   {
      datetime exchTime = TimeGMT() + (datetime)ExchangeTimezoneOffset*3600;
      TimeToStruct(exchTime,dt);
   }
   else
      TimeToStruct(TimeCurrent(),dt);

   if(dt.day_of_week==0 || dt.day_of_week==6) return false;
   if(dt.day_of_week==5 && dt.hour >= FridayCloseHour) return false;
   return true;
}

bool IsTradeServerConnected()
{
   return (bool)TerminalInfoInteger(TERMINAL_CONNECTED) && (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && (bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) && (bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
}

bool IsMarginOK(double lots, ENUM_ORDER_TYPE orderType, double price)
{
   if(lots<=0.0) return false;
   if(MinMarginLevelPercent<=0.0) return true;
   double margin=0.0;
   if(!OrderCalcMargin(orderType,_Symbol,lots,price,margin)){ HandleTradeError("OrderCalcMargin"); return false; }
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double currMargin=AccountInfoDouble(ACCOUNT_MARGIN);
   double futureMargin=currMargin+margin;
   if(futureMargin<=0.0) return true;
   double futureLevel=equity/futureMargin*100.0;
   if(futureLevel<MinMarginLevelPercent)
   {
      string msg=StringFormat("Margin FAILED: Lots=%.2f ReqMargin=%.2f CurrMargin=%.2f FutureLevel=%.1f%% < Min %.1f%%",lots,margin,currMargin,futureLevel,MinMarginLevelPercent);
      Print(msg); SendSafetyAlert("Margin Check Failed",msg);
      return false;
   }
   return true;
}

bool IsDailyLossCircuitBreakerOK()
{
   if(MaxDailyLossPercent<=0.0) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   datetime todayMidnight=StructToTime(dt) - (datetime)dt.hour*3600 - (datetime)dt.min*60 - (datetime)dt.sec;
   if(lastDailyResetDay!=todayMidnight){ lastDailyResetDay=todayMidnight; circuitBreakerActive=false; circuitBreakerDay=0; }
   if(circuitBreakerActive && circuitBreakerDay==todayMidnight) return false;

   if(!HistorySelect(todayMidnight, TimeCurrent())) return true;
   double netPnL=0.0;
   int totalDeals=HistoryDealsTotal();
   for(int i=totalDeals-1;i>=0;i--)
   {
      ulong dealTicket=HistoryDealGetTicket(i);
      if(dealTicket==0) continue;
      long magic=(long)HistoryDealGetInteger(dealTicket,DEAL_MAGIC);
      if(magic!=MagicNumber) continue;
      string sym=HistoryDealGetString(dealTicket,DEAL_SYMBOL);
      if(sym!=_Symbol) continue;
      long entryType=(long)HistoryDealGetInteger(dealTicket,DEAL_ENTRY);
      if(entryType!=DEAL_ENTRY_OUT && entryType!=DEAL_ENTRY_OUT_BY) continue;
      double profit=HistoryDealGetDouble(dealTicket,DEAL_PROFIT);
      double swap=HistoryDealGetDouble(dealTicket,DEAL_SWAP);
      double comm=HistoryDealGetDouble(dealTicket,DEAL_COMMISSION);
      netPnL+=profit+swap+comm;
   }
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double threshold=-balance*(MaxDailyLossPercent/100.0);
   if(netPnL < threshold)
   {
      circuitBreakerActive=true; circuitBreakerDay=todayMidnight;
      string msg=StringFormat("CIRCUIT BREAKER: Net loss %.2f incl swap+comm exceeds %.1f%% of balance %.2f (threshold %.2f) Magic=%d",netPnL,MaxDailyLossPercent,balance,threshold,MagicNumber);
      Print(msg); SendSafetyAlert("Circuit Breaker Triggered",msg);
      return false;
   }
   return true;
}

bool IsDuplicateGuardOK()
{
   int count=0;
   int totalPos=PositionsTotal();
   for(int i=totalPos-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!PositionSelectByTicket(t)) continue;
      long m=(long)PositionGetInteger(POSITION_MAGIC);
      string s=PositionGetString(POSITION_SYMBOL);
      if(m==MagicNumber && s==_Symbol) count++;
   }
   if(count>=MaxOpenPositionsPerMagic) return false;

   int totalOrd=OrdersTotal();
   for(int i=totalOrd-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i); if(t==0) continue;
      long m=(long)OrderGetInteger(ORDER_MAGIC);
      string s=OrderGetString(ORDER_SYMBOL);
      if(m==MagicNumber && s==_Symbol) return false;
   }
   return count==0;
}

bool IsNewBar()
{
   datetime curTime[1];
   if(CopyTime(_Symbol,_Period,0,1,curTime)<=0) return false;
   if(curTime[0]==lastBarTime) return false;
   lastBarTime=curTime[0];
   return true;
}

bool HasOpenPositionForMagic(){ int total=PositionsTotal(); for(int i=total-1;i>=0;i--){ ulong t=PositionGetTicket(i); if(t==0) continue; if(!PositionSelectByTicket(t)) continue; long m=(long)PositionGetInteger(POSITION_MAGIC); string s=PositionGetString(POSITION_SYMBOL); if(m==MagicNumber && s==_Symbol) return true; } return false; }
bool HasPendingOrderForMagic(){ int total=OrdersTotal(); for(int i=total-1;i>=0;i--){ ulong t=OrderGetTicket(i); if(t==0) continue; long m=(long)OrderGetInteger(ORDER_MAGIC); string s=OrderGetString(ORDER_SYMBOL); if(m==MagicNumber && s==_Symbol) return true; } return false; }

bool IsSpreadOK()
{
   long sprd=0;
   if(!SymbolInfoInteger(_Symbol,SYMBOL_SPREAD,sprd)) return false;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask==0.0||bid==0.0) return false;
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(point==0.0) return false;
   long live=(long)((ask-bid)/point);
   long cur = (sprd > live ? sprd : live); // FIXED: no MathMax double->long conversion
   return cur<=MaxSpreadPoints;
}

void HandleTradeError(string context)
{
   int err=GetLastError();
   if(err==0) return;
   string desc=""; switch(err){ case 10004: desc="Requote"; break; case 10006: desc="Request rejected"; break; case 10008: desc="Invalid request"; break; case 10015: desc="Invalid price"; break; case 10016: desc="Invalid stops"; break; case 10018: desc="Market closed"; break; case 10019: desc="No money"; break; case 10027: desc="Autotrading disabled"; break; case 10030: desc="Invalid fills"; break; default: desc="Unknown"; break; }
   string msg=StringFormat("TRADE ERROR in %s: Code=%d (%s) Retcode=%d Time=%s Magic=%d",context,err,desc,trade.ResultRetcode(),TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES|TIME_SECONDS),MagicNumber);
   Print(msg); SendSafetyAlert("Trade Error - "+context,msg);
}

void SendSafetyAlert(string subject, string message)
{
   if(EnablePushNotifications){ string push=subject+" | "+message; if(StringLen(push)>255) push=StringSubstr(push,0,252)+"..."; if(!SendNotification(push)) Print("SendNotification failed ",GetLastError()); }
   if(EnableEmailAlerts){ string emailSubject=StringFormat("[%s] %s - Magic %d",_Symbol,subject,MagicNumber); if(!SendMail(emailSubject,message)) Print("SendMail failed ",GetLastError()); }
}

double CalculateLots(double stopDistancePoints)
{
   if(stopDistancePoints<=0.0) return 0.0;
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance<=0.0) return 0.0;
   double riskMoney=balance*(RiskPercent/100.0);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double lotStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(tickValue==0.0||tickSize==0.0||lotStep==0.0||point==0.0) return 0.0;
   double ticksInStop=(stopDistancePoints*point)/tickSize;
   double lossPerLot=ticksInStop*tickValue;
   if(lossPerLot<=0.0) return 0.0;
   double lots=riskMoney/lossPerLot;
   lots=MathFloor(lots/lotStep)*lotStep;
   if(lots<minLot) return 0.0;
   if(lots>maxLot) lots=maxLot;
   return NormalizeDouble(lots,8);
}

bool OpenLong(double atrValue)
{
   if(atrValue<=0.0) return false;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask==0.0||bid==0.0) return false;
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(point==0.0) return false;
   double stopPoints=(atrValue/point)*ATR_StopMultiplier;
   double tpPoints=stopPoints*RewardRatio;
   long stopsLevel=0; SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL,stopsLevel);
   if(stopPoints<(double)stopsLevel){ stopPoints=(double)stopsLevel; tpPoints=stopPoints*RewardRatio; }
   if(tpPoints<(double)stopsLevel) tpPoints=(double)stopsLevel;
   double slPrice=ask-stopPoints*point;
   double tpPrice=ask+tpPoints*point;
   double lots=CalculateLots(stopPoints);
   if(lots<=0.0) return false;
   if(!IsMarginOK(lots,ORDER_TYPE_BUY,ask)) return false;
   long spreadPoints=(long)((ask-bid)/point);
   bool result=trade.Buy(lots,_Symbol,0.0,slPrice,tpPrice,"Long "+IntegerToString(MagicNumber));
   if(!result){ HandleTradeError("OpenLong"); return false; }
   ulong ticket=trade.ResultOrder(); if(ticket==0) ticket=trade.ResultDeal();
   LogTradeOpen(ticket,_Symbol,"BUY",lots,slPrice,tpPrice,spreadPoints,TimeCurrent());
   SendSafetyAlert("Trade Opened - BUY", StringFormat("Ticket=%I64u %s BUY Lots=%.2f SL=%.5f TP=%.5f Spread=%dpts",ticket,_Symbol,lots,slPrice,tpPrice,(int)spreadPoints));
   return true;
}

bool OpenShort(double atrValue)
{
   if(atrValue<=0.0) return false;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask==0.0||bid==0.0) return false;
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(point==0.0) return false;
   double stopPoints=(atrValue/point)*ATR_StopMultiplier;
   double tpPoints=stopPoints*RewardRatio;
   long stopsLevel=0; SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL,stopsLevel);
   if(stopPoints<(double)stopsLevel){ stopPoints=(double)stopsLevel; tpPoints=stopPoints*RewardRatio; }
   if(tpPoints<(double)stopsLevel) tpPoints=(double)stopsLevel;
   double slPrice=bid+stopPoints*point;
   double tpPrice=bid-tpPoints*point;
   double lots=CalculateLots(stopPoints);
   if(lots<=0.0) return false;
   if(!IsMarginOK(lots,ORDER_TYPE_SELL,bid)) return false;
   long spreadPoints=(long)((ask-bid)/point);
   bool result=trade.Sell(lots,_Symbol,0.0,slPrice,tpPrice,"Short "+IntegerToString(MagicNumber));
   if(!result){ HandleTradeError("OpenShort"); return false; }
   ulong ticket=trade.ResultOrder(); if(ticket==0) ticket=trade.ResultDeal();
   LogTradeOpen(ticket,_Symbol,"SELL",lots,slPrice,tpPrice,spreadPoints,TimeCurrent());
   SendSafetyAlert("Trade Opened - SELL", StringFormat("Ticket=%I64u %s SELL Lots=%.2f SL=%.5f TP=%.5f Spread=%dpts",ticket,_Symbol,lots,slPrice,tpPrice,(int)spreadPoints));
   return true;
}

void LogTradeOpen(ulong ticket, string symbol, string direction, double lots, double sl, double tp, long spreadPoints, datetime time)
{
   PrintFormat("TRADE_OPEN | Ticket=%I64u Symbol=%s Dir=%s Lots=%.2f SL=%.5f TP=%.5f SpreadPts=%d Time=%s Magic=%d",
               ticket,symbol,direction,lots,sl,tp,spreadPoints,TimeToString(time,TIME_DATE|TIME_MINUTES|TIME_SECONDS),MagicNumber);
}

void LogTradeClose(ulong ticket, string symbol, string direction, double lots, double profit, datetime time)
{
   PrintFormat("TRADE_CLOSE | Ticket=%I64u Symbol=%s Dir=%s Lots=%.2f Profit=%.2f Time=%s Magic=%d",
               ticket,symbol,direction,lots,profit,TimeToString(time,TIME_DATE|TIME_MINUTES|TIME_SECONDS),MagicNumber);
   SendSafetyAlert("Trade Closed", StringFormat("Ticket=%I64u %s %s Lots=%.2f Profit=%.2f",ticket,symbol,direction,lots,profit));
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   ulong dealTicket=trans.deal;
   if(dealTicket==0) return;
   if(!HistoryDealSelect(dealTicket)) return;
   long magic=(long)HistoryDealGetInteger(dealTicket,DEAL_MAGIC);
   if(magic!=MagicNumber) return;
   string sym=HistoryDealGetString(dealTicket,DEAL_SYMBOL);
   if(sym!=_Symbol) return;
   long entryType=(long)HistoryDealGetInteger(dealTicket,DEAL_ENTRY);
   if(entryType!=DEAL_ENTRY_OUT && entryType!=DEAL_ENTRY_OUT_BY) return;
   double profit=HistoryDealGetDouble(dealTicket,DEAL_PROFIT);
   double swap=HistoryDealGetDouble(dealTicket,DEAL_SWAP);
   double comm=HistoryDealGetDouble(dealTicket,DEAL_COMMISSION);
   double total=profit+swap+comm;
   double vol=HistoryDealGetDouble(dealTicket,DEAL_VOLUME);
   long dealType=(long)HistoryDealGetInteger(dealTicket,DEAL_TYPE);
   string dir=(dealType==DEAL_TYPE_SELL)?"BUY":"SELL";
   LogTradeClose(dealTicket,_Symbol,dir,vol,total,(datetime)HistoryDealGetInteger(dealTicket,DEAL_TIME));
}

bool IsAscTriangle(int shift){ int bars=Bars(_Symbol,_Period); if(shift+30>=bars) return false; double highs[30], lows[30]; if(CopyHigh(_Symbol,_Period,shift,30,highs)<=0) return false; if(CopyLow(_Symbol,_Period,shift,30,lows)<=0) return false; double top=highs[ArrayMaximum(highs)]; int flat=0; for(int i=0;i<30;i++) if(MathAbs(highs[i]-top)/top<0.0015) flat++; if(flat<2) return false; double sumX=0.0,sumY=0.0,sumXY=0.0,sumX2=0.0; for(int i=0;i<30;i++){ sumX+=i; sumY+=lows[i]; sumXY+=i*lows[i]; sumX2+=i*i; } double denom=30*sumX2-sumX*sumX; if(denom==0.0) return false; double slope=(30*sumXY-sumX*sumY)/denom; if(slope<=0.0) return false; double close1[1]; if(CopyClose(_Symbol,_Period,shift,1,close1)<=0) return false; return close1[0]>top*1.0003; }
bool IsDescTriangle(int shift){ int bars=Bars(_Symbol,_Period); if(shift+30>=bars) return false; double highs[30], lows[30]; if(CopyHigh(_Symbol,_Period,shift,30,highs)<=0) return false; if(CopyLow(_Symbol,_Period,shift,30,lows)<=0) return false; double bottom=lows[ArrayMinimum(lows)]; int flat=0; for(int i=0;i<30;i++) if(MathAbs(lows[i]-bottom)/bottom<0.0015) flat++; if(flat<2) return false; double sumX=0.0,sumY=0.0,sumXY=0.0,sumX2=0.0; for(int i=0;i<30;i++){ sumX+=i; sumY+=highs[i]; sumXY+=i*highs[i]; sumX2+=i*i; } double denom=30*sumX2-sumX*sumX; if(denom==0.0) return false; double slope=(30*sumXY-sumX*sumY)/denom; if(slope>=0.0) return false; double close1[1]; if(CopyClose(_Symbol,_Period,shift,1,close1)<=0) return false; return close1[0]<bottom*0.9997; }
bool IsBullEngulfEMA50(int shift){ int bars=Bars(_Symbol,_Period); if(shift+2>=bars) return false; double open1[1], close1[1], open2[1], close2[1], low1[1], low2[1]; if(CopyOpen(_Symbol,_Period,shift,1,open1)<=0) return false; if(CopyClose(_Symbol,_Period,shift,1,close1)<=0) return false; if(CopyOpen(_Symbol,_Period,shift+1,1,open2)<=0) return false; if(CopyClose(_Symbol,_Period,shift+1,1,close2)<=0) return false; if(CopyLow(_Symbol,_Period,shift,1,low1)<=0) return false; if(CopyLow(_Symbol,_Period,shift+1,1,low2)<=0) return false; if(close2[0]>=open2[0]) return false; if(close1[0]<=open1[0]) return false; if(open1[0]>close2[0]||close1[0]<open2[0]) return false; double ema50[1], ema50Prev[1]; if(CopyBuffer(ema50_handle,0,shift,1,ema50)<=0) return false; if(CopyBuffer(ema50_handle,0,shift+1,1,ema50Prev)<=0) return false; return (low1[0]<=ema50[0]*1.002 && close1[0]>ema50[0]) || (low2[0]<=ema50Prev[0]*1.005 && close1[0]>ema50[0]); }
bool IsBearEngulfEMA50(int shift){ int bars=Bars(_Symbol,_Period); if(shift+2>=bars) return false; double open1[1], close1[1], open2[1], close2[1], high1[1], high2[1]; if(CopyOpen(_Symbol,_Period,shift,1,open1)<=0) return false; if(CopyClose(_Symbol,_Period,shift,1,close1)<=0) return false; if(CopyOpen(_Symbol,_Period,shift+1,1,open2)<=0) return false; if(CopyClose(_Symbol,_Period,shift+1,1,close2)<=0) return false; if(CopyHigh(_Symbol,_Period,shift,1,high1)<=0) return false; if(CopyHigh(_Symbol,_Period,shift+1,1,high2)<=0) return false; if(close2[0]<=open2[0]) return false; if(close1[0]>=open1[0]) return false; if(open1[0]<close2[0]||close1[0]>open2[0]) return false; double ema50[1], ema50Prev[1]; if(CopyBuffer(ema50_handle,0,shift,1,ema50)<=0) return false; if(CopyBuffer(ema50_handle,0,shift+1,1,ema50Prev)<=0) return false; return (high1[0]>=ema50[0]*0.998 && close1[0]<ema50[0]) || (high2[0]>=ema50Prev[0]*0.995 && close1[0]<ema50[0]); }
bool IsInsideBarBO(int shift){ int bars=Bars(_Symbol,_Period); if(shift+2>=bars) return false; double h2[1], h3[1], l2[1], l3[1], c1[1], o1[1]; if(CopyHigh(_Symbol,_Period,shift+1,1,h2)<=0) return false; if(CopyHigh(_Symbol,_Period,shift+2,1,h3)<=0) return false; if(CopyLow(_Symbol,_Period,shift+1,1,l2)<=0) return false; if(CopyLow(_Symbol,_Period,shift+2,1,l3)<=0) return false; if(CopyClose(_Symbol,_Period,shift,1,c1)<=0) return false; if(CopyOpen(_Symbol,_Period,shift,1,o1)<=0) return false; return (h2[0]<h3[0] && l2[0]>l3[0] && c1[0]>h2[0] && c1[0]>o1[0]); }
bool IsInsideBarBD(int shift){ int bars=Bars(_Symbol,_Period); if(shift+2>=bars) return false; double h2[1], h3[1], l2[1], l3[1], c1[1], o1[1]; if(CopyHigh(_Symbol,_Period,shift+1,1,h2)<=0) return false; if(CopyHigh(_Symbol,_Period,shift+2,1,h3)<=0) return false; if(CopyLow(_Symbol,_Period,shift+1,1,l2)<=0) return false; if(CopyLow(_Symbol,_Period,shift+2,1,l3)<=0) return false; if(CopyClose(_Symbol,_Period,shift,1,c1)<=0) return false; if(CopyOpen(_Symbol,_Period,shift,1,o1)<=0) return false; return (h2[0]<h3[0] && l2[0]>l3[0] && c1[0]<l2[0] && c1[0]<o1[0]); }
bool IsBullFlag(int shift){ int bars=Bars(_Symbol,_Period); if(shift+13>=bars) return false; double cs[1], ce[1], c1[1]; if(CopyClose(_Symbol,_Period,shift+13,1,cs)<=0) return false; if(CopyClose(_Symbol,_Period,shift+8,1,ce)<=0) return false; if(CopyClose(_Symbol,_Period,shift,1,c1)<=0) return false; if(cs[0]==0.0) return false; if((ce[0]-cs[0])/cs[0]<0.006) return false; double highs[7], lows[7]; if(CopyHigh(_Symbol,_Period,shift+1,7,highs)<=0) return false; if(CopyLow(_Symbol,_Period,shift+1,7,lows)<=0) return false; double fh=highs[ArrayMaximum(highs)], fl=lows[ArrayMinimum(lows)]; if((fh-fl)/c1[0]>0.008) return false; return c1[0]>fh*1.0003; }
bool IsBearFlag(int shift){ int bars=Bars(_Symbol,_Period); if(shift+13>=bars) return false; double cs[1], ce[1], c1[1]; if(CopyClose(_Symbol,_Period,shift+13,1,cs)<=0) return false; if(CopyClose(_Symbol,_Period,shift+8,1,ce)<=0) return false; if(CopyClose(_Symbol,_Period,shift,1,c1)<=0) return false; if(cs[0]==0.0) return false; if((ce[0]-cs[0])/cs[0]>-0.006) return false; double highs[7], lows[7]; if(CopyHigh(_Symbol,_Period,shift+1,7,highs)<=0) return false; if(CopyLow(_Symbol,_Period,shift+1,7,lows)<=0) return false; double fh=highs[ArrayMaximum(highs)], fl=lows[ArrayMinimum(lows)]; if((fh-fl)/c1[0]>0.008) return false; return c1[0]<fl*0.9997; }
bool IsDoubleBottom(int shift){ int bars=Bars(_Symbol,_Period); if(shift+30>=bars) return false; double lows[30]; if(CopyLow(_Symbol,_Period,shift,30,lows)<=0) return false; double min1=lows[ArrayMinimum(lows)]; int pos1=ArrayMinimum(lows); double min2=DBL_MAX; for(int i=0;i<30;i++) if(MathAbs(i-pos1)>=5 && lows[i]<min2) min2=lows[i]; if(min2==DBL_MAX) return false; if(MathAbs(min1-min2)/MathAbs(min1)>0.015) return false; double highs[10]; if(CopyHigh(_Symbol,_Period,shift+1,10,highs)<=0) return false; double rh=highs[ArrayMaximum(highs)]; double close1[1]; if(CopyClose(_Symbol,_Period,shift,1,close1)<=0) return false; return close1[0]>rh*1.0003; }
bool IsRectangleLong(int shift){ int bars=Bars(_Symbol,_Period); if(shift+20>=bars) return false; double highs[20], lows[20]; if(CopyHigh(_Symbol,_Period,shift,20,highs)<=0) return false; if(CopyLow(_Symbol,_Period,shift,20,lows)<=0) return false; double hmax=highs[ArrayMaximum(highs)], hmin=highs[ArrayMinimum(highs)], lmax=lows[ArrayMaximum(lows)], lmin=lows[ArrayMinimum(lows)]; if((hmax-hmin)/hmax>0.01) return false; if((lmax-lmin)/lmax>0.01) return false; double close1[1]; if(CopyClose(_Symbol,_Period,shift,1,close1)<=0) return false; return close1[0]>hmax*1.0003; }
bool IsRectangleShort(int shift){ int bars=Bars(_Symbol,_Period); if(shift+20>=bars) return false; double highs[20], lows[20]; if(CopyHigh(_Symbol,_Period,shift,20,highs)<=0) return false; if(CopyLow(_Symbol,_Period,shift,20,lows)<=0) return false; double hmax=highs[ArrayMaximum(highs)], hmin=highs[ArrayMinimum(highs)], lmax=lows[ArrayMaximum(lows)], lmin=lows[ArrayMinimum(lows)]; if((hmax-hmin)/hmax>0.01) return false; if((lmax-lmin)/lmax>0.01) return false; double close1[1]; if(CopyClose(_Symbol,_Period,shift,1,close1)<=0) return false; return close1[0]<lmin*0.9997; }
bool IsDonchianBOLong(int shift){ int bars=Bars(_Symbol,_Period); if(shift+20>=bars) return false; double highs[19]; if(CopyHigh(_Symbol,_Period,shift+1,19,highs)<=0) return false; double highest=highs[ArrayMaximum(highs)]; double close1[1]; if(CopyClose(_Symbol,_Period,shift,1,close1)<=0) return false; return close1[0]>highest*1.0005; }
bool IsDonchianBDShort(int shift){ int bars=Bars(_Symbol,_Period); if(shift+20>=bars) return false; double lows[19]; if(CopyLow(_Symbol,_Period,shift+1,19,lows)<=0) return false; double lowest=lows[ArrayMinimum(lows)]; double close1[1]; if(CopyClose(_Symbol,_Period,shift,1,close1)<=0) return false; return close1[0]<lowest*0.9995; }
