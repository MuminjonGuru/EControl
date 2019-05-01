unit ec_Async;

{$mode Delphi}{$H+}

interface

uses
  Classes, SysUtils,  syncobjs,
  Generics.Collections
   {$IFDEF DEBUGLOG},Forms , SynCommons, SynLog,mORMotHttpClient  {$ENDIF};

type
    IAsyncSyntaxClient=interface
     procedure SwitchContext(toWorker:boolean);
     procedure WorkerDetached();
    end;
    TExceptionHandler = procedure (const e:Exception) of object;



    { TecSyntaxerThread }
    TecSyntaxerThread=class(TThread)
    protected
    FArgument:integer;
    type
      TSyntaxWorkDelegate = function:boolean of object;

     // TScheduleKind = (skTry, skRemove, skWait);
     { TSyntaxWork }
     TSyntaxWork=record
      Task:TSyntaxWorkDelegate;
      //happens when task is done(sender is thred) or cancelled(sender is nil)
      DoneHandler:TNotifyEvent;
      Arg: Integer;
      Expendable:boolean;
      {$IFDEF DEBUGLOG}Name:ansistring;{$ENDIF}
      procedure Setup(const task:TSyntaxWorkDelegate;aArg:integer;
      const doneEvent:TNotifyEvent; aExpendable:boolean
      {$IFDEF DEBUGLOG}; const name:ansistring{$ENDIF});overload;
      procedure Setup(constref other:TSyntaxWork);overload;
      procedure Clear();
      function TaskAssigned():boolean;
      function IsSame(const other:TSyntaxWork):boolean;
     end;


    TWorkQueue= TQueue<TSyntaxWork>;
    TIdleDestroyTime= 1..300;

    ///<summary>Request and wait for access to the syntaxer data</summary>


    strict protected
    FClientSyntaxer:IAsyncSyntaxClient;
    FStopCurrentTask,FSchedulingDisabled : boolean;
    FSyntaxWork  : TSyntaxWork;
    FSyntaxQueue:TWorkQueue;
    FWakeUpEvent, FTaskDoneEvent : TEvent;
    FIdleTimeStart:Cardinal;
    FSyncWall, FSchedulerWall, FTagSync: TCriticalSection;
    FSynRequestCount:integer;
    FOnError : TExceptionHandler;
    FStartTime: Cardinal;
    FIdleDestroyTime: TIdleDestroyTime;
    class var FThreadCount:integer;
    const FPauseTimeOnSyncRequest:integer=60;//in ms

    procedure HandleTaskDone(var task:TSyntaxWork);
    procedure HandleTaskStart(const task:TSyntaxWork);
    procedure HandleError(const e:Exception);

    function GetScheduled(out task:TSyntaxWork): boolean;
    function WaitForNewTask(out task:TSyntaxWork): boolean;
    procedure Execute;override;
    function ExecuteTask(const task:TSyntaxWork):boolean;
    procedure EnsureTerminated;
    procedure SetSchedulingEnabled(doEnable:boolean);

    public
    constructor Create(const syntaxer:IAsyncSyntaxClient;
                   const errorHandler:TExceptionHandler);
    destructor Destroy();override;
    function GetIsTaskAssigned():boolean;
    function GetIsWorkerThread():boolean;
    function RequestRelease(var me:TecSyntaxerThread):boolean;
    function GetSyncNowAccessible:boolean;
    procedure AcquireSync(roSync:boolean);
    procedure ReleaseSync();
//    function WaitTaskAndSync(const timeOut:Cardinal):boolean;
    function GetIsWorking():boolean; inline;
    procedure YieldData(andWait:boolean);
    procedure StopCurrentTask();
    procedure CancelExpendableTasks();
    function WaitTaskDone(time:Cardinal):boolean;
    function ScheduleWork(syntaxProc : TSyntaxWorkDelegate;aArg:integer;
                   aDoneHandler:TNotifyEvent; expendable:boolean
                   {$IFDEF DEBUGLOG}; const name:ansistring{$ENDIF}):boolean;
    procedure DoTagSync(enter:boolean);
    procedure Terminate2;
    property BusyWorking:boolean read GetIsWorking;
    property Argument:integer read FArgument;
    property IdleDestroyTime:TIdleDestroyTime read FIdleDestroyTime write FIdleDestroyTime;
  end;



function InterlockedCompareExchangeLb(var target: LongBool;
        NewValue, Comperand: LongBool): LongBool;inline;


var _ThreadMgr :TThreadManager;// workaround FPC/RTL bug
implementation

{ TecSyntaxerThread.TSyntaxWork }

procedure TecSyntaxerThread.TSyntaxWork.Setup(const task: TSyntaxWorkDelegate;
  aArg:integer; const doneEvent: TNotifyEvent; aExpendable:boolean
  {$IFDEF DEBUGLOG}; const name:ansistring{$ENDIF});
begin
    self.Task:=task; DoneHandler:=doneEvent;
    self.Arg:=aArg; self.Expendable:=aExpendable;
    {$IFDEF DEBUGLOG}
    self.Name:= name;
    {$ENDIF}
end;

procedure TecSyntaxerThread.TSyntaxWork.Setup(constref other: TSyntaxWork);
begin
  Task := other.Task; DoneHandler:=other.DoneHandler;
  Arg:=other.Arg; Expendable:=other.Expendable;
  {$IFDEF DEBUGLOG}
  Name:= other.Name;
  {$ENDIF}
end;

procedure TecSyntaxerThread.TSyntaxWork.Clear();
begin
  Task:=nil;DoneHandler:=nil;
end;

function TecSyntaxerThread.TSyntaxWork.TaskAssigned(): boolean;
begin
 result :=assigned(Task);
end;

function TecSyntaxerThread.TSyntaxWork.IsSame(const other: TSyntaxWork
  ): boolean;
begin
  result := Task = other.Task;
end;



{ TecSyntaxerThread }

function TecSyntaxerThread.GetIsWorking(): boolean;
begin
  result := FSyntaxWork.TaskAssigned();
end;



constructor TecSyntaxerThread.Create(
  const syntaxer:IAsyncSyntaxClient;
  const errorHandler:TExceptionHandler);
begin
  FIdleDestroyTime:=10;
  FClientSyntaxer:=syntaxer;
  Inc(FThreadCount);
  FSyntaxQueue := TWorkQueue.Create();
  FSynRequestCount:= 0;
  FWakeUpEvent:=TEvent.Create(nil, false, false,'');
  {$IFDEF DEBUGLOG}
  TSynLog.Add.Log(sllInfo, 'Worker thread created');
  {$ENDIF}

  FTaskDoneEvent:=TEvent.Create(nil, true, true,'');
  //  Format('TecSyntaxerThreadWake%d',[FThreadCount]));
  FTagSync :=TCriticalSection.Create();
  FSyncWall := TCriticalSection.Create();
  FSchedulerWall := TCriticalSection.Create();
  inherited Create(false);
  FreeOnTerminate:=true;
end;

procedure TecSyntaxerThread.AcquireSync(roSync:boolean);
var time:Cardinal;
    done:boolean;
begin
 done:=FSyncWall.TryEnter;
 if done then exit;
  time:=GetTickCount();
  if roSync then begin
     repeat
        FSynRequestCount:=1;
     until FSyncWall.TryEnter;

  end
  else
     FSyncWall.Enter();

  time:=GetTickCount-time;
  {$IFDEF DEBUGLOG}
  if time > 50 then
     TSynLog.Add.Log(sllWarning, 'AcquireSync waited: %d ms', [time]);
  {$ENDIF}
end;

procedure TecSyntaxerThread.ReleaseSync();
begin
//if not GetIsWorkerThread() then
//     FSynRequestCount:=0;
  {$IFDEF DEBUG}
  //if FSynRequestCount <0  then
  //  assert(false, 'ReleaseSync');
  {$ENDIF}
  FSyncWall.Release();
end;

procedure TecSyntaxerThread.StopCurrentTask();
begin
 FSchedulerWall.Enter;
 FStopCurrentTask:=true;
 FSchedulerWall.Leave;
end;

procedure TecSyntaxerThread.CancelExpendableTasks();
var task:TSyntaxWork;
    q:TWorkQueue;
begin
FSchedulerWall.Enter;
try
if FSyntaxQueue.Count>0  then begin
  q:=TWorkQueue.Create;
  for task in FSyntaxQueue do begin
        if not task.Expendable then
             q.Enqueue(task)
        else if Assigned(task.DoneHandler) then
           task.DoneHandler(nil);
  end;
  FSyntaxQueue.Clear;
   for task in q do
     FSyntaxQueue.Enqueue(task);
   q.Free();
end;

finally FSchedulerWall.Leave;end;
end;

function TecSyntaxerThread.WaitTaskDone(time: Cardinal): boolean;
var timeWaited:integer;
    wr:TWaitResult;
begin

 timeWaited:= GetTickCount();
 wr :=FTaskDoneEvent.WaitFor(time);
 result :=wr=wrSignaled;
 if not result then
  exit(false);

 timeWaited:= GetTickCount()- timeWaited;
 {$IFDEF DEBUGLOG}
   if timeWaited>50+ord(FStopCurrentTask)*200 then begin
      TSynLog.Add.Log(sllWarning, 'Waited for task done % s', [timeWaited] );
   end;
 {$ENDIF}
end;

function TecSyntaxerThread.ScheduleWork(syntaxProc: TSyntaxWorkDelegate; aArg:integer;
  aDoneHandler: TNotifyEvent; expendable:boolean {$IFDEF DEBUGLOG}; const name:ansistring{$ENDIF}): boolean;
var isBusy:boolean;
    newTask:TSyntaxWork;
    label Tail;

begin
  assert( not Terminated, 'Attempt to schedule work on terminated thread');

  if FSchedulingDisabled then
    Assert(false, 'Schedule, when it''s disabled');

  FSchedulerWall.Enter();
   try
      newTask.Setup(syntaxProc,aArg, aDoneHandler, expendable
      {$IFDEF DEBUGLOG},name{$ENDIF} );

      {$IFDEF DEBUGLOG}
         TSynLog.Add.Log(sllInfo, 'Task %s added [%d]', [name, FSyntaxQueue.Count]);
      {$ENDIF}
      FSyntaxQueue.Enqueue(newTask);
  finally
    FSchedulerWall.Leave();
  end;
  FWakeUpEvent.SetEvent;
end;

procedure TecSyntaxerThread.DoTagSync(enter: boolean);
begin
  if enter then
    FTagSync.Enter
  else
    FTagSync.Leave;
end;

procedure TecSyntaxerThread.Terminate2;
begin
 FClientSyntaxer:=nil;
 inherited Terminate;
end;

function TecSyntaxerThread.GetIsWorkerThread(): boolean;
begin
 result := self.ThreadID = _ThreadMgr.GetCurrentThreadId ;
end;

function TecSyntaxerThread.RequestRelease(var me:TecSyntaxerThread): boolean;
begin
FSchedulerWall.Enter;
result:= not GetIsWorking() ;
if result then begin
  result:= FSyntaxQueue.Count<=0;
  if result then  begin
     me:=nil;
end;
end;
if result then  Terminate;
FSchedulerWall.Leave;

end;






procedure TecSyntaxerThread.HandleTaskDone(var task:TSyntaxWork);
begin
  if assigned(task.DoneHandler) then
           task.DoneHandler(self);
 {$IFDEF DEBUGLOG}
  FStartTime:=GetTickCount()-FStartTime;
  TSynLog.Add.Log(sllTrace, 'Task %s done in %d ms',[task.Name, FStartTime]);
 {$ENDIF}
 task.Clear();
 FTaskDoneEvent.SetEvent();
 FSchedulerWall.Acquire();
 try
  FSyntaxWork.Clear;
  if (FStopCurrentTask) then
                   FStopCurrentTask:=false;
 finally  FSchedulerWall.Release(); end;

end;

procedure TecSyntaxerThread.HandleTaskStart(const task: TSyntaxWork);
begin

  FStartTime:=GetTickCount();
  {$IFDEF DEBUGLOG}
  TSynLog.Add.Log(sllInfo, 'Task %s started', [task.Name]);
  {$ENDIF}
  FTaskDoneEvent.ResetEvent();
  FSyntaxWork.Setup(task);
end;

function TecSyntaxerThread.GetScheduled(out task:TSyntaxWork): boolean;
begin
 result:= false;
 if FSchedulingDisabled then exit;
  FSchedulerWall.Enter;
  try
  result:= FSyntaxQueue.Count >0;
  if result then begin
   task.Setup(FSyntaxQueue.Dequeue());
  end;
  finally FSchedulerWall.Leave; end;
end;

function TecSyntaxerThread.WaitForNewTask(out task:TSyntaxWork): boolean;
var waitRslt:TWaitResult;
    timeWait:Cardinal;
begin
   result := GetScheduled(task);
   if result then exit;

   waitRslt:= FWakeUpEvent.WaitFor(1000);

   Assert(waitRslt <> wrError, 'FWakeUpEvent released? Must never!');
   FSchedulerWall.Enter;
   result := GetScheduled(task);
   if not result then begin
     timeWait:=GetTickCount -FIdleTimeStart;
     if (timeWait>FIdleDestroyTime*1000) and not (Terminated) then begin
       if assigned(FClientSyntaxer) then begin
       TThread.Queue(nil,
       FClientSyntaxer.WorkerDetached);
       end;

     end;
   end;
   FSchedulerWall.Leave;
end;

procedure TecSyntaxerThread.Execute;
    var
    taskDelegate:TSyntaxWork;
    taskComplete, gotTask: boolean;
    timeElapsed :Cardinal;
    const task_max_ms = 10*1000;//10 seconds, or goto hell
begin
  {$IFDEF DEBUGLOG}
  TSynLog.Add.Log(sllInfo, 'Worker thread started %', [ThreadID]);
  {$ENDIF}
  FSynRequestCount:= 0;
  taskDelegate.Clear;
  FIdleTimeStart:=GetTickCount();
  repeat
   if not taskDelegate.TaskAssigned() then begin // fetch new task

     gotTask:=WaitForNewTask(taskDelegate);
     if  not gotTask then  continue;
   end;

   AcquireSync(false);

   FClientSyntaxer.SwitchContext(true);
   try
     HandleTaskStart(taskDelegate);
     timeElapsed:=self.GetTickCount();
     taskComplete:=   ExecuteTask(taskDelegate) ;
   finally
     HandleTaskDone(taskDelegate);
     FClientSyntaxer.SwitchContext(false);
     ReleaseSync();
   end;
   FIdleTimeStart:=GetTickCount();
  until Terminated;

  FClientSyntaxer:=nil;
end;

function TecSyntaxerThread.ExecuteTask(const task: TSyntaxWork):boolean;
begin
  result := true; // in case of error
  assert(GetIsWorkerThread(),
             'ExecuteTask must only be invoked asynchronously');
  FArgument:=task.Arg;
  try
   result := task.Task();
  except
   on e:Exception do  HandleError(e);
  end;
end;

procedure TecSyntaxerThread.EnsureTerminated;
var wr:integer;
begin
 StopCurrentTask();
 Terminate;
 //wr :=self.WaitFor();
//  assert(wr=0);
end;

procedure TecSyntaxerThread.SetSchedulingEnabled(doEnable: boolean);
begin
 FSchedulerWall.Enter;
 FSchedulingDisabled:= not doEnable;
 FSchedulerWall.Leave;
end;

procedure TecSyntaxerThread.YieldData(andWait:boolean);
begin
  if FSynRequestCount<=0 then exit;
  FClientSyntaxer.SwitchContext(false);
  FSynRequestCount:=0;
  FSyncWall.Release;
  {$IFDEF DEBUGLOG}
  TSynLog.Add.Log( sllEnter, 'Yield Data!');
  {$ENDIF}
  if andWait then
     Sleep(300)
  else Yield;
  FSyncWall.Acquire;
  FClientSyntaxer.SwitchContext(true);
end;

procedure TecSyntaxerThread.HandleError(const e: Exception);
begin
  if assigned(FOnError) then
     FOnError(e);
end;



destructor TecSyntaxerThread.Destroy();
begin
  EnsureTerminated;
  {$IFDEF DEBUGLOG}
  if not Application.Terminated then
  TSynLog.Add.Log(sllInfo,'Worker destroyed  %', [ThreadID]);
  {$ENDIF}
  FreeAndNil(FWakeUpEvent);
  FreeAndNil(FSyncWall);
  FreeAndNil(FSchedulerWall);
  FreeAndNil(FTagSync);
  FreeAndNil(FSyntaxQueue);
  inherited Destroy();
end;

function TecSyntaxerThread.GetIsTaskAssigned(): boolean;
begin
  result := FSyntaxWork.TaskAssigned();
end;

function TecSyntaxerThread.GetSyncNowAccessible: boolean;
begin
 result:= FSyncWall.TryEnter;
 if result then FSyncWall.Leave;
end;

//function TecSyntaxerThread.WaitTaskAndSync(const timeOut: Cardinal): boolean;
//var timeStart, elapsed:Cardinal;
//begin
// assert(self<> TThread.CurrentThread,
//    'WaitTaskAsync is to called outside worker thread');
//
// timeStart := GetTickCount();
// SetSchedulingEnabled(false);
// repeat
//  FTaskDoneEvent.WaitFor(timeout);
//  elapsed := GetTickCount() - timeStart;
//  result :=not GetIsWorking();
// until result or (elapsed > timeOut) ;
// {$IFDEF DEBUGLOG}
// if elapsed> 350 then
// TSynLog.Add.Log(sllWarning, 'Waited task %d ms', [elapsed]);
// {$ENDIF}
// if result then
//      AcquireSync(false);
// SetSchedulingEnabled(true);
//end;





function InterlockedCompareExchangeLb(var target: LongBool;
        NewValue, Comperand: LongBool): LongBool;inline;
var _target : LongWord absolute Target;
begin
 result:=LongBool( InterlockedCompareExchange(_target, LongWord(NewValue),
          LongWord(Comperand) ) );
end;


{$IFDEF DEBUGLOG}
var hlog:TSQLHttpClient;
procedure MakeLogger();
begin
 TSynLog.Family.LevelStackTrace:=[sllWarning,sllCustom1] ;
 TSynLog.Family.Level:=LOG_VERBOSE;
 TSynLog.Family.PerThreadLog:=ptIdentifiedInOnFile;
 try
 hlog:=TSQLHttpClient.CreateForRemoteLogging('127.0.0.1', TSynLog);
 except end;

 TSynLog.Add.LogThreadName('Main');
end;

procedure StopLogger;
begin

 TSynLog.Family.EchoRemoteStop();

end;

{$ENDIF}

initialization
GetThreadManager(_ThreadMgr);
{$IFDEF DEBUGLOG}
 MakeLogger();
{$ENDIF}
finalization
  {$IFDEF DEBUGLOG}
    StopLogger;
//    Halt(0);
  {$ENDIF}
end.

