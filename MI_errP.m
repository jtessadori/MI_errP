classdef MI_errP
    properties
        fs=512; % WARNING: DO NOT change this. Amplifier acquisition rate can only be changed from its panel in Simulink, it is here for reference
        MIbufferLength=.5; % WARNING: as above, changing this here DOES NOT modify them in Simulink. Make sure desired lenghts are correct IN BOTH
        errPbufferLength=5; % Same as above. Parameters can be changed in triggeredBuffer block initialization mask in the Simulink block
        rawData;
        cursorPos;
        targetPos;
        ETcursorPos;
        condition;
        figureParams;
        colorScheme;
        modelName;
        timeTriggeredEvents;
        errPclassifier;
        MIclassifier
        outputLog;
        recLength
        trainingParams;
        timingParams;
        feedbackType; % 1 - no tactile feedback, 2 - tactile feedback
        learningRate=1e-4;
        nPositions=11; % Please, keep this odd
        vibrationParams;
        maxNtrials;
        takeStep=@(obj)obj.movList(length(obj.outputLog.time)+1)*sign(obj.targetPos-obj.cursorPos);
        movList=[];
        targetList=[];
        nPauses=0;
    end
    properties (Dependent)
        currTime;
    end
    properties (Hidden)
        CDlength;
        possibleConditions={'V feedback','VT feedback'};
        isExpClosed=0;
        actualTarget;
        lapFilterCoeffs;
        nextCursorPos;
        lastCursorPos;
        errPdataWindow;
        isPausing=0;
        isSerialPortOpen=0;
        currPhase=1;
        isDebugging=0;
    end
    methods
        %% Constructor
        function obj=MI_errP(varargin)
            % Exactly one argument may be passed: another instance of a
            % MI_errP class. The only properties that will be used are the
            % classifiers, everything else is left at default values.
            if nargin>=1
                obj.MIclassifier=varargin{1}.MIclassifier;
                obj.errPclassifier=varargin{1}.errPclassifier;
            end
            % Some parameters (e.g. sampling frequency of amplifier and
            % buffer window length) cannot be changed directly from here,
            % so please do make sure that they're matching with the current
            % settings of relevant Simulink model.
            
            % Set length of initial countdown, in seconds
            if obj.isDebugging
                obj.CDlength=2;
            else
                obj.CDlength=15;
            end
            
            % Load target and movement keys
            load keys.mat
            obj.movList=movementKey;
            obj.targetList=targetKey;
            obj.maxNtrials=length(movementKey);
            
            % Define timing parameters
            if obj.isDebugging
                obj.timingParams.targetReachedPause=.2; % Wait at target position, once reached
                obj.timingParams.MIestimationLength=.5; % Integrate data over this many seconds before drawing conclusion
                obj.timingParams.MIstepLength=.1; % Distance, in seconds, between evaluations of MI
                obj.timingParams.errPestimationLength=.2; % Length of window used for errP estimation, following movement
                obj.timingParams.vibrationLength=.1; % Length, in seconds, of armband vibration
                obj.timingParams.interStepInterval=obj.timingParams.MIestimationLength+obj.timingParams.errPestimationLength+.1; % Wait between cursor movements, in seconds
            else
                obj.timingParams.targetReachedPause=2; % Wait at target position, once reached
                obj.timingParams.MIestimationLength=3; % Integrate data over this many seconds before drawing conclusion
                obj.timingParams.MIstepLength=.1; % Distance, in seconds, between evaluations of MI
                obj.timingParams.errPestimationLength=1; % Length of window used for errP estimation, following movement
                obj.timingParams.vibrationLength=1; % Length, in seconds, of armband vibration
                obj.timingParams.interStepInterval=obj.timingParams.MIestimationLength+obj.timingParams.errPestimationLength+1; % Wait between cursor movements, in seconds
            end
            
            % Define squares positions
            obj.figureParams.squarePos=linspace(-.95,.95,obj.nPositions);
            
            % Define chance of error during training
            if obj.isDebugging
                obj.trainingParams.errChance=0.1;
            else
                obj.trainingParams.errChance=0.3;
            end
            
            % Set colors for different objects
            obj.colorScheme.bg=[.05,.05,.05];
            % Randomize color setup to reudce expectations
            obj.colorScheme.possibleColors={[.4,0,.1],[0,.4,0],[.8,.2,0],[.6,.6,0]};
            %             obj.colorScheme.colorOrder=randperm(length(obj.colorScheme.possibleColors));
            %             obj.colorScheme.targetColor=obj.colorScheme.possibleColors{obj.colorScheme.colorOrder(1)};
            %             obj.colorScheme.cursorColorMI=obj.colorScheme.possibleColors{obj.colorScheme.colorOrder(2)};
            %             obj.colorScheme.cursorColorRest=obj.colorScheme.possibleColors{obj.colorScheme.colorOrder(3)};
            %             obj.colorScheme.cursorColorReached=obj.colorScheme.possibleColors{obj.colorScheme.colorOrder(4)};
            obj.colorScheme.targetColor=obj.colorScheme.possibleColors{1};
            obj.colorScheme.cursorColorMI=obj.colorScheme.possibleColors{2};
            obj.colorScheme.cursorColorRest=obj.colorScheme.possibleColors{4};
            obj.colorScheme.cursorColorReached=obj.colorScheme.possibleColors{3};
            obj.colorScheme.cursorColor=obj.colorScheme.cursorColorMI;
            obj.colorScheme.edgeColor=[.4,.4,.4];
            
            % Set shape for squares
            obj.figureParams.squareShape.X=[-.05,.05,.05,-.05];
            obj.figureParams.squareShape.Y=[-.05,-.05,.05,.05];
            
            % Set shape for arrows
            obj.figureParams.leftArrow.X=[-1,-.4,-.4,1,1,-.4,-.4]/20;
            obj.figureParams.leftArrow.Y=[0,.5,.2,.2,-.2,-.2,-.5]/20;
            obj.figureParams.rightArrow.X=[-1,.4,.4,1,.4,.4,-1]/20;
            obj.figureParams.rightArrow.Y=[.2,.2,.5,0,-.5,-.2,-.2]/20;
            obj.figureParams.headlessArrow.X=[-1,1,1,-1]/20;
            obj.figureParams.headlessArrow.Y=[.2,.2,-.2,-.2]/20;
            
            % Set shape for eye-tracker cursor
            obj.figureParams.ETcursor.X=[.005,-.005,-.005,.005];
            obj.figureParams.ETcursor.Y=[.005,.005,-.005,-.005];
            
            % Define vibration intensities for different events
            obj.vibrationParams.MItrain=.4;
            obj.vibrationParams.feedback=1;
            
            % Initialize a few things
            obj.outputLog.time=[];
            obj.outputLog.cursorPos=[];
            obj.outputLog.targetPos=[];
            obj.outputLog.errPtimes=[];
            obj.outputLog.errPest=[];
            obj.outputLog.MItimes=[];
            obj.outputLog.MIest=[];
            obj.outputLog.MIprob=[];
            obj.outputLog.targetsReached.time=[];
            obj.outputLog.targetsReached.targetPos=[];
            obj.outputLog.targetsReached.correctTarget=[];
            obj.outputLog.correctMovement=[];
            obj.outputLog.MIindex=cell(0);
            obj.outputLog.MItrialMov=[];
            obj.outputLog.MIfeats=[];
            obj.outputLog.MIupdateTime=[];
            obj.outputLog.MIlbls=[];
            obj.outputLog.paramsHistory=[];
            obj.outputLog.errPfeats=[];
            obj.outputLog.correctMov=[];
            obj.outputLog.actualMov=[];
            
            % Ask user whether to start experiment right away
            clc;
            if ~strcmpi(input('Start experiment now? [Y/n]\n','s'),'n')
                obj=runExperiment(obj);
            end
        end
        
        % Other methods
        function obj=runExperiment(obj)
            % Variables on base workspace will be used to trigger closing
            % of experiment
            assignin('base','isExpClosing',0);
            
            % Sets name of Simulink model to be used for acquisition
            obj.modelName='SimpleAcquisition_16ch_2014a_RT_preProc';
            
            % Prompts user to select a condition
            obj=selectCondition(obj);
            obj=setConditionSpecificParams(obj);
            
            % Determine starting position for cursor and target, and first
            % movement
            obj.targetPos=obj.targetList(1);
            obj.cursorPos=(1+obj.nPositions)/2;
            obj.nextCursorPos=min(obj.nPositions,max(1,obj.cursorPos+obj.takeStep(obj)));
            
            % Prepares serial port for vibrating motor control
            obj=obj.prepareSerialPort;
            
            % Prepares Simulink model (i.e. starts recording, basically)
            obj.prepareSimulinkModel;
            
            % Opens black figure as background
            obj=createExpFigure(obj);
            
            % Generates array of time triggered events
            obj.timeTriggeredEvents{1}=timeTriggeredEvent('cursorMovementCallback',obj.timingParams.interStepInterval+obj.CDlength);
            obj.timeTriggeredEvents{2}=timeTriggeredEvent('processErrPbuffer',Inf);
            obj.timeTriggeredEvents{3}=timeTriggeredEvent('processMIbuffer',0);
            obj.timeTriggeredEvents{4}=timeTriggeredEvent('targetReachedCallback',Inf);
            obj.timeTriggeredEvents{5}=timeTriggeredEvent('estimateMovementDirection',Inf);
            obj.timeTriggeredEvents{6}=timeTriggeredEvent('switchOffVibration',Inf);
            obj.timeTriggeredEvents{7}=timeTriggeredEvent('startMI',0);
%             obj.timeTriggeredEvents{8}=timeTriggeredEvent('trainMI',obj.timingParams.phase1Length+obj.CDlength);
%             obj.timeTriggeredEvents{9}=timeTriggeredEvent('trainErrP',obj.timingParams.phase1Length+obj.timingParams.phase2Length+obj.CDlength);
            
            % Shows a countdown
            obj.startCountdown(obj.CDlength);
            
            % Perform bulk of experiment
            obj=manageExperiment(obj);
            
            % Closes exp window and saves data
            obj.closeExp;
        end
        
        function obj=manageExperiment(obj)
            global motorSerialPort
            % Generate file name used to save experiment data
            fileName=datestr(now,30);
            
            % Set pausing variable on base workspace
            assignin('base','togglePause',0);
            
            % Experiment control loop
%             try
            while ~evalin('base','isExpClosing')&&length(obj.outputLog.time)<obj.maxNtrials
%             while ~evalin('base','isExpClosing')&&obj.currTime<obj.timingParams.phase1Length+obj.timingParams.phase2Length+obj.timingParams.phase3Length
                pause(0.001);
                for currTTevent=1:length(obj.timeTriggeredEvents);
                    obj=checkAndExecute(obj.timeTriggeredEvents{currTTevent},obj.currTime,obj);
                    pause(0.0001);
                end
                if (evalin('base','togglePause'))
                    assignin('base','togglePause',0);
                    if obj.isPausing
                        obj.isPausing=0;
                        set_param(obj.modelName,'SimulationCommand','Continue');
                    else
                        obj.isPausing=1;
                        set_param(obj.modelName,'SimulationCommand','Pause');
                    end
                end
            end
%             catch
%                 keyboard;
%             end
            pause(3);
            obj.isExpClosed=1;
            delete(gcf);
            set_param(obj.modelName,'SimulationCommand','Stop');
            set_param(obj.modelName,'StartFcn','')
            obj.rawData=evalin('base','rawData');
            save(fileName,'obj');
            
            % Stop vibration and close serial port communication
            if obj.isSerialPortOpen
                fprintf(motorSerialPort,'e8\n');
                pause(0.003)
                fprintf(motorSerialPort,'p\n');
                pause(0.003)
                fprintf(motorSerialPort,'r0\n');
                pause(0.003)
                fprintf(motorSerialPort,'e4\n');
                pause(0.003)
                fprintf(motorSerialPort,'p\n');
                pause(0.003)
                fprintf(motorSerialPort,'r0\n');
                fclose(motorSerialPort);
                delete(motorSerialPort);
            end
            
            % Clear variables from base workspace
            evalin('base','clear listener*');
            evalin('base','clear toggleTraining');
        end
        
        function obj=createExpFigure(obj)
            % Set figure properties
            obj.figureParams.handle=gcf;
            set(obj.figureParams.handle,'Tag',mfilename,...
                'Toolbar','none',...
                'MenuBar','none',...
                'Units','normalized',...
                'Resize','off',...
                'NumberTitle','off',...
                'Name','',...
                'Color',obj.colorScheme.bg,...
                'RendererMode','Manual',...
                'Renderer','OpenGL',...
                'WindowKeyPressFcn',@KeyPressed,...
                'CloseRequestFcn',@OnClosing,...
                'WindowButtonMotionFcn',@onMouseMove);
            
            % Plot squares
            for currSquare=1:obj.nPositions
                obj.figureParams.squareHandles(currSquare)=patch(obj.figureParams.squarePos(currSquare)+obj.figureParams.squareShape.X,obj.figureParams.squareShape.Y,obj.colorScheme.bg);
                set(obj.figureParams.squareHandles(currSquare),'EdgeColor',obj.colorScheme.edgeColor);
            end
            
            % Draw arrow, then fix its position
            obj.figureParams.arrowHandle=patch(obj.figureParams.leftArrow.X+20,obj.figureParams.leftArrow.Y,obj.colorScheme.cursorColor);
            obj=obj.drawArrow;
            
            % Set and remove figure axis
            ylim([-1,1]);
            xlim([-1,1]);
            set(gcf,'units','normalized','position',[0,0,1,1]);
            axis square
            axis('off')
            
            % Draw target
            obj.figureParams.targetHandle=patch(obj.figureParams.squarePos(obj.targetPos)+obj.figureParams.squareShape.X,obj.figureParams.squareShape.Y,obj.colorScheme.targetColor);
            
            % Draw cursor
            obj.figureParams.cursorHandle=patch(obj.figureParams.squarePos(obj.cursorPos)+obj.figureParams.squareShape.X,obj.figureParams.squareShape.Y,obj.colorScheme.cursorColor);
            
            % Draw eye tracking cursor (offscreen)
            obj.figureParams.ETcursorHandle=patch(obj.figureParams.ETcursor.X+10,obj.figureParams.ETcursor.Y,[.7,.7,.7]);
            
            % Remove box around figure
            %             undecorateFig;
        end
        
        function obj=cursorMovementCallback(obj)
            % Log timing
            obj.timeTriggeredEvents{1}.triggersLog=[obj.timeTriggeredEvents{1}.triggersLog,obj.currTime];
            
            % Test whether planned movement is correct and update
            % corresponding log
            isMovementCorrect=abs(obj.targetPos-obj.nextCursorPos)<abs(obj.targetPos-obj.cursorPos);
            obj.outputLog.correctMovement=cat(1,obj.outputLog.correctMovement,isMovementCorrect);
            
            % Moves cursor to next position
            obj.lastCursorPos=obj.cursorPos;
            obj.cursorPos=obj.nextCursorPos;
            obj.timeTriggeredEvents{7}.nextTrigger=obj.currTime+obj.timingParams.interStepInterval-obj.timingParams.MIestimationLength;
            
            % Start band vibration
            obj.startBandVibration(obj.vibrationParams.feedback,'feedback');
            obj.timeTriggeredEvents{6}.nextTrigger=obj.currTime+obj.timingParams.vibrationLength;
            
            % Remove arrow (i.e. move it outside of screen)
            set(obj.figureParams.arrowHandle,'X',get(obj.figureParams.arrowHandle,'X')+20);
            
            % Test if current target is reached
            %             if obj.cursorPos==obj.targetPos
            % Test if either extreme position has been reached
            if ismember(obj.cursorPos,[1,obj.nPositions])
                obj.timeTriggeredEvents{1}.nextTrigger=Inf;
                obj.timeTriggeredEvents{7}.nextTrigger=Inf;
                obj.timeTriggeredEvents{4}.nextTrigger=obj.currTime+obj.timingParams.targetReachedPause;
                obj.timeTriggeredEvents{2}.nextTrigger=obj.currTime+obj.timingParams.errPestimationLength;
                set(obj.figureParams.cursorHandle,'XData',get(obj.figureParams.squareHandles(obj.cursorPos),'XData'),'FaceColor',obj.colorScheme.cursorColorReached);
                
%                 % Print number of reached target
%                 textString=sprintf('%d/%d',sum(obj.outputLog.targetsReached.targetPos==obj.cursorPos)+1,sum(obj.targetList==obj.cursorPos));
%                 if ~isfield(obj.figureParams,'targetText')
%                     obj.figureParams.targetText=text(mean(get(obj.figureParams.cursorHandle,'XData')),mean(get(obj.figureParams.cursorHandle,'YData'))+.2,textString,'HorizontalAlignment','center');
%                 else
%                     set(obj.figureParams.targetText,'Position',[mean(get(obj.figureParams.cursorHandle,'XData')),mean(get(obj.figureParams.cursorHandle,'YData'))+.2],'String',textString);
%                 end
%                 set(obj.figureParams.targetText,'Color','white','FontSize',64);
                return; % Exit early from function
            else
                % Draw new cursor position
                set(obj.figureParams.cursorHandle,'XData',get(obj.figureParams.squareHandles(obj.cursorPos),'XData'),'FaceColor',obj.colorScheme.cursorColorRest);
            end
            
            if obj.currPhase==1
                % If training session, decide next position
                obj.nextCursorPos=min(obj.nPositions,max(1,obj.cursorPos+obj.takeStep(obj)));
                
                % Set next evaluation time for this function
                obj.timeTriggeredEvents{1}.nextTrigger=obj.currTime+obj.timingParams.interStepInterval;
            else
                % Set events to trigger data retrieval
                % and analysis of MI data
                obj.timeTriggeredEvents{5}.nextTrigger=obj.currTime+obj.timingParams.interStepInterval;
                
                % Set next evaluation time for this function
                obj.timeTriggeredEvents{1}.nextTrigger=Inf;
            end
            % Recover and log errP data
            obj.timeTriggeredEvents{2}.nextTrigger=obj.currTime+obj.timingParams.errPestimationLength;
            
            % Add relevant info to log
            obj.outputLog.cursorPos=cat(1,obj.outputLog.cursorPos,obj.cursorPos);
            obj.outputLog.targetPos=cat(1,obj.outputLog.targetPos,obj.targetPos);
            obj.outputLog.time=cat(1,obj.outputLog.time,obj.currTime);
            obj.outputLog.correctMov=cat(1,obj.outputLog.correctMov,sign(obj.targetPos-obj.cursorPos));
            obj.outputLog.actualMov=cat(1,obj.outputLog.actualMov,obj.nextCursorPos-obj.cursorPos);
        end
        
        function obj=processErrPbuffer(obj)
            % Log timing and reset trigger time
            obj.timeTriggeredEvents{2}.nextTrigger=Inf;
            obj.timeTriggeredEvents{2}.triggersLog=[obj.timeTriggeredEvents{2}.triggersLog,obj.currTime];
            
            % Recover data buffer from base workspace (Simulink puts them
            % there)
            dataWindow=evalin('base','currErrPdata');
            dataTimeStamp=obj.currTime;
            
            % Data buffer is longer than required and not exactly synched
            % with cursor movement. Recover correct section (starting from
            % cursor movement)
            lastCursorMovTime=obj.timeTriggeredEvents{1}.triggersLog(end);
            currDelay=dataTimeStamp-lastCursorMovTime;
            dataWindow=dataWindow(round((obj.errPbufferLength-currDelay)*obj.fs+1):round((obj.errPbufferLength-currDelay+obj.timingParams.errPestimationLength)*obj.fs),:);
            
            % Recover frequency features
            freqFeats=evalin('base','BP');
            
            % Join freq and time Data
            feats=cat(1,freqFeats,reshape(resample(dataWindow,64,512),[],1));
            
            % Make sure some relevant information is present during
            % debugging
            if obj.isDebugging&&~isempty(obj.outputLog.correctMovement)
                feats(3)=obj.outputLog.correctMovement(end)+sum(feats(1:2));
            end
            
            % If not training, perform classification
            if obj.currPhase>1
                if obj.currPhase==3
                    currEst=obj.errPclassifier.clsfr.predict(feats(obj.errPclassifier.featsIdx)');
                else
                    currEst=obj.outputLog.correctMovement(end);
                end
                
                % Update MI classifier parameters. Apply update on each data
                % sample that was predicting chosen class
%                 if ~currEst&&~isempty(obj.outputLog.MIindex) % i.e. an error is detected
                if ~isempty(obj.outputLog.MIindex)
                    relSamples=obj.outputLog.MIindex{end};
                    relEst=obj.outputLog.MIest(relSamples);
                    majorityEst=median(relEst)>.5;
                    relFeats=obj.outputLog.MIfeats(relSamples,:);
                    relProb=obj.MIclassifier.computeProb(relFeats(:,obj.MIclassifier.featsIdx));
                    updatingSamples=find((obj.outputLog.MIest(relSamples)>.5)==majorityEst);
                    wIn=[obj.MIclassifier.Intercept;obj.MIclassifier.B];
%                     t=~majorityEst; % Supposedly, I should be here only if last movement was wrong
                    t=((majorityEst-.5)*2*(currEst-.5)*2)>0;
%                     t=(obj.targetPos-obj.cursorPos)>0;
                    for currSample=1:length(updatingSamples)
                        updatingFeats=relFeats(updatingSamples(currSample),obj.MIclassifier.featsIdx);
                        E=relProb(updatingSamples(currSample));
                        wOut=MI_errP.updateWeights(wIn,updatingFeats,E,t,obj.learningRate);
                        obj.MIclassifier.Intercept=wOut(1);
                        obj.MIclassifier.B=wOut(2:end);
                        computeProb=@(x)1./(1+exp(-(x*wOut(2:end)+wOut(1))));
                        obj.MIclassifier.computeProb=computeProb;
                        obj.MIclassifier.predict=@(x)computeProb(x)>.5;
                    end
%                     fprintf('%d\n',t);
                    % Logs changing parameters
                    obj.outputLog.MIupdateTime=cat(1,obj.outputLog.MIupdateTime,dataTimeStamp);
                    obj.outputLog.paramsHistory=cat(1,obj.outputLog.paramsHistory,wIn');
                end
            else
                currEst=NaN;
            end
            
            % Log relevant data
            obj.outputLog.errPtimes=cat(1,obj.outputLog.errPtimes,dataTimeStamp);
            obj.outputLog.errPest=cat(1,obj.outputLog.errPest,currEst);
            obj.outputLog.errPfeats=cat(1,obj.outputLog.errPfeats,feats');
        end
        
        function obj=processMIbuffer(obj)
            % Log timing and reset trigger time
            obj.timeTriggeredEvents{3}.nextTrigger=obj.currTime+obj.timingParams.MIstepLength;
            obj.timeTriggeredEvents{3}.triggersLog=[obj.timeTriggeredEvents{3}.triggersLog,obj.currTime];
            
            % Recover data buffer from base workspace (Simulink puts them
            % there)
            freqFeats=evalin('base','BP');
            dataTimeStamp=obj.currTime;
            
            % Make sure some relevant information is present during
            % debugging, then provide drift for coefficients during
            % training
            if obj.isDebugging
                debugCoeffs=[.006;-.0025];
                freqFeats(3)=freqFeats(1:2)'*debugCoeffs+double(obj.targetPos~=1);
%                 if obj.currPhase>1
%                     debugCoeffs=debugCoeffs.*(1+randn(size(debugCoeffs))*.3.*(rand(size(debugCoeffs))>.99));
%                 end
            end
            
            % If not training, perform classification
            if obj.currPhase>1
                currProb=obj.MIclassifier.computeProb(freqFeats(obj.MIclassifier.featsIdx)');
            else
                currProb=NaN;
            end
            
            % If MI tactile feedback is occurring, modulate amplitude
            if ~isempty(obj.timeTriggeredEvents{1}.triggersLog)&&obj.currTime-obj.timeTriggeredEvents{1}.triggersLog(end)>obj.timingParams.interStepInterval-obj.timingParams.MIestimationLength&&obj.currTime-obj.timeTriggeredEvents{1}.triggersLog(end)<obj.timingParams.interStepInterval
                vibrValue=0.5-(obj.outputLog.MIprob(end));
                obj.startBandVibration(sign(vibrValue)*sqrt(vibrValue),'MIcontrol');
            end
            
            % Log relevant data
            obj.outputLog.MItimes=cat(1,obj.outputLog.MItimes,dataTimeStamp);
            obj.outputLog.MIest=cat(1,obj.outputLog.MIest,currProb>.5);
            obj.outputLog.MIprob=cat(1,obj.outputLog.MIprob,currProb);
            obj.outputLog.MIfeats=cat(1,obj.outputLog.MIfeats,freqFeats');
            obj.outputLog.MIlbls=cat(1,obj.outputLog.MIlbls,double(obj.targetPos~=1));
        end
        
        function obj=targetReachedCallback(obj)
            % Log timing and reset trigger time
            obj.timeTriggeredEvents{4}.nextTrigger=Inf;
            obj.timeTriggeredEvents{4}.triggersLog=[obj.timeTriggeredEvents{4}.triggersLog,obj.currTime];
            
            % Add relevant info to log
            obj.outputLog.targetsReached.time=cat(1,obj.outputLog.targetsReached.time,obj.currTime);
            obj.outputLog.targetsReached.targetPos=cat(1,obj.outputLog.targetsReached.targetPos,obj.targetPos);
            obj.outputLog.targetsReached.correctTarget=cat(1,obj.outputLog.targetsReached.correctTarget,obj.targetPos==obj.cursorPos);
            
%             % Hide reached targets text, if present
%             if isfield(obj.figureParams,'targetText')
%                 set(obj.figureParams.targetText,'Color',obj.colorScheme.bg);
%             end

            % Decide if it is time to take a break
            pauseList=round(length(obj.targetList)/obj.nPauses:length(obj.targetList)/obj.nPauses:length(obj.targetList));
            if ismember(length(obj.outputLog.targetsReached.time),pauseList)
                msgH=msgbox('This is a pause. Start again when ready.','Pause','modal');
                uiwait(msgH);
            end
            
            % Reset cursor pos
            obj.cursorPos=(1+obj.nPositions)/2;
            set(obj.figureParams.cursorHandle,'XData',get(obj.figureParams.squareHandles(obj.cursorPos),'XData'),'FaceColor',obj.colorScheme.cursorColorMI);
            
            % Choose new target position and move it
            if obj.isDebugging
                obj.targetPos=obj.nPositions+1-obj.targetPos;
            else
                obj.targetPos=obj.targetList(length(obj.outputLog.targetsReached.time));
            end
            set(obj.figureParams.targetHandle,'XData',get(obj.figureParams.squareHandles(obj.targetPos),'XData'));
            
            % Draw arrow
            obj=obj.drawArrow;
            
            if obj.currPhase==1
                % If training session, decide next position
                obj.nextCursorPos=min(obj.nPositions,max(1,obj.cursorPos+obj.takeStep(obj)));
                
                % Sets vibration cue
                obj.startBandVibration(obj.vibrationParams.MItrain,'MItraining');
                
                % Set next cursor movement time
                obj.timeTriggeredEvents{1}.nextTrigger=obj.currTime+obj.timingParams.MIestimationLength;
            else
                % If testing session, set events to trigger data retrieval
                % and analysis
                obj.timeTriggeredEvents{5}.nextTrigger=obj.currTime+obj.timingParams.MIestimationLength;
            end
            % Add relevant info to log
            obj.outputLog.cursorPos=cat(1,obj.outputLog.cursorPos,obj.cursorPos);
            obj.outputLog.targetPos=cat(1,obj.outputLog.targetPos,obj.targetPos);
            obj.outputLog.time=cat(1,obj.outputLog.time,obj.currTime);
        end
        
        function obj=estimateMovementDirection(obj)
            % Log call timing
            obj.timeTriggeredEvents{5}.triggersLog=[obj.timeTriggeredEvents{5}.triggersLog,obj.currTime];
            
            if isempty(obj.timeTriggeredEvents{7}.triggersLog)
                relevantEntries=obj.outputLog.MItimes>obj.CDlength;
            else
%                 relevantEntries=obj.outputLog.MItimes>obj.timeTriggeredEvents{7}.triggersLog(end);
                relevantEntries=obj.outputLog.MItimes>obj.currTime-obj.timingParams.MIestimationLength;
            end
            
            % Next position is function of past classification results
            % (just take median of all available estimates in the window of
            % interest, i.e. since last cursor movement)
            currEst=nanmedian(obj.outputLog.MIest(relevantEntries));
            
            suggestedMov=sign(currEst-.5);
            obj.nextCursorPos=min(obj.nPositions,max(1,obj.cursorPos+suggestedMov));
            
            % Log indexes of data used for estimation and decision taken
            obj.outputLog.MIindex{end+1}=find(relevantEntries);
            obj.outputLog.MItrialMov=cat(1,obj.outputLog.MItrialMov,suggestedMov);
            
            % Reset trigger time
            obj.timeTriggeredEvents{5}.nextTrigger=Inf;
            
            % Perform suggested step and move on
            obj.timeTriggeredEvents{1}.nextTrigger=obj.currTime;
        end
               
        function obj=switchOffVibration(obj)
            % Log timing and reset trigger time
            obj.timeTriggeredEvents{6}.nextTrigger=Inf;
            obj.timeTriggeredEvents{6}.triggersLog=[obj.timeTriggeredEvents{6}.triggersLog,obj.currTime];
            
            % Switch intensity level
            obj.startBandVibration(obj.vibrationParams.MItrain,'none');
        end
        
        function obj=startMI(obj)
            % Log timing and reset trigger time
            obj.timeTriggeredEvents{7}.nextTrigger=Inf;
            obj.timeTriggeredEvents{7}.triggersLog=[obj.timeTriggeredEvents{7}.triggersLog,obj.currTime];
            
            % Change cursor color
            set(obj.figureParams.cursorHandle,'FaceColor',obj.colorScheme.cursorColorMI);
            
            % Draw arrow
            obj=drawArrow(obj);
            
            % Switch intensity level, if training
            if obj.currPhase==1
                obj.startBandVibration(obj.vibrationParams.MItrain,'MItraining');
            else
                obj.startBandVibration((obj.outputLog.MIprob(end)-0.5),'MIcontrol');
            end
        end
        
        function obj=trainMI(obj)
            % Log timing and reset trigger time
            obj.timeTriggeredEvents{8}.nextTrigger=Inf;
            obj.timeTriggeredEvents{8}.triggersLog=[obj.timeTriggeredEvents{8}.triggersLog,obj.currTime];
            
            % Train MI classifier, if one is not passed at construction
            % WARNING: because of massive issue with extreme outliers in
            % data, classifier will be trained on surrogate dataset
            if isempty(obj.MIclassifier)
                obj.MIclassifier=computeMIclassifier(obj);
            end
            
            % If debugging, reset classifier parameters or update will
            % be useless
            if obj.isDebugging
                obj.MIclassifier.B=zeros(size(obj.MIclassifier.B));
                obj.MIclassifier.Intercept=0;
%                 obj.MIclassifier.B=(1+0.2*randn(size(obj.MIclassifier.B))).*obj.MIclassifier.B;
            end
            
            % Switch to phase 2
            obj.currPhase=2;
        end
        
        function obj=trainErrP(obj)
            % Log timing and reset trigger time
            obj.timeTriggeredEvents{9}.nextTrigger=Inf;
            obj.timeTriggeredEvents{9}.triggersLog=[obj.timeTriggeredEvents{9}.triggersLog,obj.currTime];
            
            % Train MI classifier
            obj.errPclassifier=computeErrPclassifier(obj);
            
            % If debugging, reset MI classifier parameters or update will
            % be useless
            if obj.isDebugging
                obj.MIclassifier.B=zeros(size(obj.MIclassifier.B));
                obj.MIclassifier.Intercept=0;
                %                 obj.MIclassifier.B=(1+0.2*randn(size(obj.MIclassifier.B))).*obj.MIclassifier.B;
            end
            
            % Switch to phase 3
            obj.currPhase=3;
        end
        
        function obj=drawArrow(obj)
            if obj.currPhase==1
                if obj.targetPos==1
                    set(obj.figureParams.arrowHandle,'X',obj.figureParams.squarePos(obj.cursorPos)+obj.figureParams.leftArrow.X,'Y',obj.figureParams.leftArrow.Y+0.1);
                else
                    set(obj.figureParams.arrowHandle,'X',obj.figureParams.squarePos(obj.cursorPos)+obj.figureParams.rightArrow.X,'Y',obj.figureParams.rightArrow.Y+0.1);
                end
            else
                set(obj.figureParams.arrowHandle,'X',obj.figureParams.squarePos(obj.cursorPos)+obj.figureParams.headlessArrow.X,'Y',obj.figureParams.headlessArrow.Y+0.1);
            end
        end
        
        function obj=selectCondition(obj)
            currCond=0;
            while true
                clc;
                for currPossibleCond=1:length(obj.possibleConditions)
                    fprintf('[%d] - %s;\n',currPossibleCond,obj.possibleConditions{currPossibleCond});
                end
                currCond=input('\nPlease select desired condition: ');
                if ismember(currCond,1:length(obj.possibleConditions));
                    break
                end
            end
            obj.condition.conditionID=currCond;
        end
        
        function obj=setConditionSpecificParams(obj)
            % 'V feedback','VT feedback'
            switch obj.condition.conditionID
                case 1
                    obj.feedbackType=1;
                case 2
                    obj.feedbackType=2;
            end
        end
        
        function prepareSimulinkModel(obj)
            % Check whether simulink model file can be found
            if ~exist(obj.modelName,'file')
                warning('Cannot find model %s.\nPress Enter to continue.\n',obj.modelName);
                input('');
                [fileName,pathName]=uigetfile('*.slx','Select Simulink model to load:');
                obj.modelName=sprintf('%s\\%s',pathName,fileName);
            end
            % Load model
            load_system(obj.modelName);
            
            % Check whether simulation was already running, and, in case,
            % stop it
            if bdIsLoaded(obj.modelName)&&strcmp(get_param(obj.modelName,'SimulationStatus'),'running')
                set_param(obj.modelName,'SimulationCommand','Stop');
            end
            
            % Add event listener to triggered buffer event.
            set_param(obj.modelName,'StartFcn',sprintf('simulinkModelStartFcn(''%s'')',obj.modelName))
            set_param(obj.modelName,'StopTime','inf');
            set_param(obj.modelName,'FixedStep',['1/',num2str(obj.fs)]);
            set_param(obj.modelName,'SimulationCommand','Start');
        end
        
        function obj=prepareSerialPort(obj)
            global motorSerialPort
            motorSerialPort=serial('COM9','BaudRate',230400,'Parity','even');
            try
                fopen(motorSerialPort);
                pause(1);
                fprintf(motorSerialPort,'e4\n');
                pause(0.3);
                fprintf(motorSerialPort,'p\n');
                pause(0.3);
                fprintf(motorSerialPort,'e8\n');
                pause(0.3);
                fprintf(motorSerialPort,'p\n');
                pause(0.3);
                obj.isSerialPortOpen=1;
            catch
                warning('Unable to open serial port communication with band motors');
            end
        end
        
        function wait(obj,pauseLength)
            startTime=get_param(obj.modelName,'SimulationTime');
            while strcmp(get_param(obj.modelName,'SimulationStatus'),'running')&&get_param(obj.modelName,'SimulationTime')<=startTime+pauseLength
                pause(1/(2*obj.fs));
            end
        end
        
        function startCountdown(obj,nSecs)
            % countdown to experiment start
            figure(obj.figureParams.handle)
            for cntDown=nSecs:-1:1
                if ~exist('textHandle','var')
                    textHandle=text(0,.5,num2str(cntDown));
                else
                    set(textHandle,'String',num2str(cntDown));
                end
                set(textHandle,'Color','white','FontSize',64,'HorizontalAlignment','center');
                pause(1);
            end
            delete(textHandle);
        end
        
        function [clsfr,cvAcc]=computeErrPclassifier(obj)
            % Recover feats and labels
            [allFeats,lbls]=recoverErrPdata(obj);
                        
            % Train classifier and present cross-validation results
            fprintf('Training ErrP classifier. Please be patient, it will take some time...\n\n');
            [clsfr,~,cvAcc]=testClassifier2(lbls,allFeats,'blocktype','subsequent','nBlocks',1,'threshold',.3,'selectionType','zScore');
%             [clsfr,~,cvAcc]=testClassifier2(lbls,allFeats,'blocktype','subsequent','nblocks',10,'threshold',.6,'selectionType','histOverlap');
        end
        
        function cvAcc=testErrPrequiredLength(obj)
            % Recover feats and labels
            [allFeats,lbls]=recoverErrPdata(obj);
            
            % Preserve original data
            allFeatsBak=allFeats;
            lblsBak=lbls;
            
            % Test classifier accuracy for different lengths
            nTrials=25:25:length(lblsBak);
            cvAcc=zeros(length(nTrials),1);
            for currLength=1:length(nTrials)
                allFeats=allFeatsBak(1:nTrials(currLength),:);
                lbls=lblsBak(1:nTrials(currLength));
                
                % Present cross-validation results
                [~,~,cvAcc(currLength)]=testClassifier2(lbls,allFeats,'blocktype','subsequent','nblocks',6,'threshold',.3);
%                 [~,~,cvAcc(currLength)]=testClassifier2(lbls,allFeats,'blocktype','subsequent','nblocks',10,'featureN',4,'selectionType','histOverlap');
                plot(nTrials(1:currLength),cvAcc(1:currLength))
                pause(0.01);
                fprintf('%d/%d\n',currLength,length(nTrials));
            end
        end
        
        function [allFeats,lbls]=recoverErrPdata(obj)
            lbls=obj.outputLog.correctMovement(1:size(obj.outputLog.errPfeats,1));
            allFeats=obj.outputLog.errPfeats;
        end
        
        function BACC=testErrPclassifier(obj)
            % Compute predictions
            errPest=obj.errPclassifier.clsfr.predict(obj.outputLog.errPfeats(:,obj.errPclassifier.featsIdx));
            
            % Compute BACC
            testAcc=@(x,y)(sum((x==1).*(y==1))./sum(x==1)+sum((x==0).*(y==0))./sum(x==0))*.5;
            BACC=testAcc(obj.outputLog.correctMovement(1:length(errPest)),errPest>.5);
        end
        
        function clsfr=computeMIclassifier(obj)
            % Recover MI data
            [allFeats,lbls]=recoverMIdata(obj);
            
            allFeatsSurr=zeros(size(allFeats));
            allFeatsSD=zeros(2,size(allFeats,2));
            allFeatsMean=zeros(2,size(allFeats,2));
            for currClass=1:2
                allFeatsSD(currClass,:)=1.4826*mad(allFeats(lbls==currClass-1,:),1);
                allFeatsMean(currClass,:)=median(allFeats(lbls==currClass-1,:));
            end
            for currFeat=1:length(allFeatsMean)
                for currClass=1:2
                    relIdx=find(lbls==currClass-1);
                    allFeatsSurr(relIdx,currFeat)=randn(length(relIdx),1)*allFeatsSD(currClass,currFeat)+allFeatsMean(currClass,currFeat);
                end
            end
            
            % Train classifier
            fprintf('Training MI classifier. Please be patient, it will take some time...\n');
            clsfr=testClassifier2(lbls,allFeatsSurr,'blocktype','subsequent','nblocks',1,'threshold',.1,'selectionType','zScore','classifiertype','logistic');
        end
        
        function [allFeats,lbls,relMIidx]=recoverMIdata(obj)
            relMIidx=cell(length(obj.outputLog.time),1);
            for currMov=1:length(obj.outputLog.time)
                lastMovTime=obj.outputLog.time(currMov);
                relMIidx{currMov}=find((obj.outputLog.MItimes>lastMovTime-obj.timingParams.MIestimationLength)&(obj.outputLog.MItimes<lastMovTime));
            end
            relMIidxMat=cell2mat(relMIidx);
            lbls=obj.outputLog.MIlbls(relMIidxMat);
            allFeats=obj.outputLog.MIfeats(relMIidxMat,:);
        end
        
        function AUC=testMIstaticClassifier(obj)
            %             % Recover feats and labels
            %             [allFeats,lbls]=recoverMIdata(obj);
            %
            %             % Define link function and compute estimates
            %             computeProb=@(x)1./(1+exp(-(x*obj.MIclassifier.B+obj.MIclassifier.Intercept)));
            %             MIest=computeProb(allFeats(:,obj.MIclassifier.featsIdx));
            %
            %             % Compute AUC
            %             [~,~,~,AUC]=perfcurve(lbls,MIest,1);
            % Define link function and compute estimates
            computeProb=@(x)1./(1+exp(-(x*obj.MIclassifier.B+obj.MIclassifier.Intercept)));
            MIestLong=computeProb(obj.outputLog.MIfeats(:,obj.MIclassifier.featsIdx));
            
            % Average est for each movement
            MIest=zeros(length(obj.outputLog.MIindex),1);
            for currTrial=1:length(obj.outputLog.MIindex)
                MIest(currTrial)=mean(MIestLong(obj.outputLog.MIindex{currTrial}));
            end
            
            % Compute AUC
            [~,~,~,AUC]=perfcurve(double(obj.outputLog.targetPos>1),MIest,1);
        end
        
        function AUC=testMIonlineClassifier(obj)
            % Average est for each movement
            MIestLong=obj.outputLog.MIest;
            MIest=zeros(length(obj.outputLog.MIindex),1);
            for currTrial=1:length(obj.outputLog.MIindex)
                MIest(currTrial)=mean(MIestLong(obj.outputLog.MIindex{currTrial}));
            end
            
            % Compute AUC
            [~,~,~,AUC]=perfcurve(double(obj.outputLog.targetPos>1),MIest,1);
        end
        
        function startBandVibration(obj,intensity,vibrationType)
            global motorSerialPort
            
            % Intensity will be passed as a parameter between 0 and 1. Need
            % to rescale it as an integer between 0 and 120 for serial port
            % to work properly
            if obj.isSerialPortOpen
                % If tactile feedback is disabled, set intensity to 0
                serialIntensity=round(intensity*120)*(obj.feedbackType-1);
                
                % Use global variable for motorSerialPort so that it can be
                % accessed also in case of unexpected program stop
                switch vibrationType
                    case 'feedback' % Vibration position should match last cursor movement
                        vibrationDir=obj.lastCursorPos-obj.cursorPos;
                    case 'MItraining' % Vibration position should match current direction
                        vibrationDir=sign(obj.cursorPos-obj.targetPos);
                    case 'none' % Stop vibration, regardless of intensity
                        vibrationDir=0;
                    case 'MIcontrol'
                        vibrationDir=sign(intensity);
                        serialIntensity=abs(serialIntensity);
                end
                switch vibrationDir
                    case -1
                        fprintf(motorSerialPort,'e4\n');
                        pause(0.01);
                        fprintf(motorSerialPort,'r%d\n',serialIntensity);
                        pause(0.01);
                        fprintf(motorSerialPort,'e8\n');
                        pause(0.01);
                        fprintf(motorSerialPort,'r0\n');
                    case 1
                        fprintf(motorSerialPort,'e8\n');
                        pause(0.01)
                        fprintf(motorSerialPort,'r%d\n',serialIntensity);
                        pause(0.01);
                        fprintf(motorSerialPort,'e4\n');
                        pause(0.01);
                        fprintf(motorSerialPort,'r0\n');
                    case 0
                        fprintf(motorSerialPort,'e8\n');
                        pause(0.01)
                        fprintf(motorSerialPort,'r0\n');
                        pause(0.01);
                        fprintf(motorSerialPort,'e4\n');
                        pause(0.01);
                        fprintf(motorSerialPort,'r0\n');
                end
            end
        end
        
        function plotErrPs(obj)
            % Normalize data
            normalize=@(x)(x-repmat(mean(x),size(x,1),1))./repmat(1.4826*mad(x,1),size(x,1),1);
            normData=normalize(obj.rawData.data);
            
            [B,A]=cheby1(4,6,[1,10]/(obj.fs/2));
            lbls=obj.outputLog.correctMovement;
            
            % Apply spatial and freq filters
            %             lapData=obj.applyLapFilter(obj.rawData.data);
            carData=MI_errP.applyLapFilter(normData);
            freqData=filter(B,A,carData);
            
            relWins=zeros(length(obj.outputLog.errPtimes),obj.fs*2,size(obj.rawData.data,2));
            for currWin=1:size(relWins,1)
                relWins(currWin,:,:)=freqData((obj.outputLog.errPtimes(currWin)-.5)*obj.fs+1:(obj.outputLog.errPtimes(currWin)+1.5)*obj.fs,:);
            end
            lbls=lbls(1:length(obj.outputLog.errPtimes));
            
            t=linspace(-0.5,1.5,obj.fs*2);
            load('elMap16_MI_err.mat')
            for currCh=1:16
                subplot(4,4,currCh);
                plot(t,squeeze(median(relWins(lbls==0,:,currCh))),'k');
                hold on;
                plot(t,squeeze(median(relWins(lbls==1,:,currCh))),'r');
                plot(t,squeeze(median(relWins(lbls==0,:,currCh)))-squeeze(median(relWins(lbls==1,:,currCh))),'g','LineWidth',2);
                axis([-.5,1.5,-.1,.1]);
                set(gca,'XTickLabel',[],'YTickLabel',[]);
                xlabel(elMap16.elName{currCh});
            end
        end
        
        function plotMIspectrograms(obj)
            % Normalize data
            normalize=@(x)(x-repmat(mean(x),size(x,1),1))./repmat(1.4826*mad(x,1),size(x,1),1);
            normData=normalize(obj.rawData.data);
            
            [B,A]=cheby1(4,6,[2,60]/(obj.fs/2));
            
            % Apply spatial and freq filters
            lapData=obj.applyLapFilter(normData);
            freqData=filter(B,A,lapData);
            
            % Recover electrode map to name figures and define plot names
            load('elMap16_MI_err.mat')
            plotNames={'Left MI','Right MI'};
            
            % Compute resulting spectrogram
            lvl=6;
%             leftMoves=((obj.outputLog.targetPos==1).*obj.outputLog.correctMovement(1:length(obj.outputLog.targetPos))+((obj.outputLog.targetPos~=1).*~obj.outputLog.correctMovement(1:length(obj.outputLog.targetPos))));
%             leftMoves=leftMoves(1:end-1); % Remove last entry, as required window might exceed recording length
%             winStarts=round((obj.timeTriggeredEvents{1}.triggersLog+obj.timingParams.interStepInterval-obj.timingParams.MIestimationLength)*obj.fs);
%             winStarts=winStarts(1:length(leftMoves));
            leftMoves=double(obj.outputLog.targetPos==1);
            winStarts=(obj.timeTriggeredEvents{1}.triggersLog-obj.timingParams.MIestimationLength)*obj.fs;
            spectMat=zeros(size(freqData,2),length(winStarts),64,obj.timingParams.MIestimationLength*obj.fs);
            for currCh=1:size(freqData,2);
                wpt=wpdec(freqData(:,currCh),lvl,'sym6');
                [S,~,F]=wpspectrum(wpt,obj.fs);
                
                % Recover relevant windows, normalize and average them
                for currWin=1:length(winStarts)
                    dataWin=S(:,winStarts(currWin)+1:winStarts(currWin)+obj.fs*obj.timingParams.MIestimationLength);
                    baseLine=mean(dataWin(:,1:obj.fs/2),2);
                    baseMat=repmat(baseLine,1,obj.timingParams.MIestimationLength*obj.fs);
                    dataWin=(dataWin-baseMat)./(dataWin+baseMat)*.5;
                    spectMat(currCh,currWin,:,:)=dataWin;
                end
                moveSpect{1}=mean(spectMat(currCh,logical(leftMoves),:,:),2);
                moveSpect{2}=mean(spectMat(currCh,~logical(leftMoves),:,:),2);
                figure;
                set(gcf,'Name',(elMap16.elName{currCh}));
                for currPlot=1:2
                    subplot(1,2,currPlot);
                    imagesc(squeeze(moveSpect{currPlot}),[-.15,.15])
                    colorbar;
                    axis([0,obj.fs*obj.timingParams.MIestimationLength,.5,64/256*40]);
                    title(plotNames{currPlot});
                    set(gca,'XTick',linspace(0,obj.timingParams.MIestimationLength*obj.fs,6),'XTickLabel',linspace(0,obj.timingParams.MIestimationLength,6),'YDir','normal','YTick',linspace(1,64,32),'YTickLabel',F(round(linspace(1,64,32))))
                end
            end
        end
        
        function outData=preProcData(obj)
            % Prepare freq filters
            windowLength=.4;
            nBands=19;
            nChannels=16;
            for currFreq=1:nBands
                [B(currFreq,:),A(currFreq,:)]=cheby1(2,6,([2*currFreq,2*(currFreq+1)]/obj.fs)/2); %#ok<AGROW>
            end
            Bfir=ones(1,round(obj.fs*windowLength))/round(obj.fs*windowLength);
            
            % Prepare spatial filters
            fltrWeights=zeros(16);
            try
                load('elMap16_MI_err.mat')
            catch ME %#ok<NASGU>
                warning('''elMap16_MI_err'' not found. Electrode map required for laplacian filters.');
                return;
            end
            for currEl=1:16
                neighborsMap=zeros(size(elMap16.elMat));
                neighborsMap(elMap16.elMat==currEl)=1;
                neighborsMap=imdilate(neighborsMap,strel('diamond',1));
                neighborsMap(elMap16.elMat==currEl)=0;
                validNeighbors=logical(neighborsMap.*elMap16.elMat);
                fltrWeights(currEl,elMap16.elMat(validNeighbors))=-1/sum(sum(validNeighbors));
                fltrWeights(currEl,currEl)=1;
            end
            
            % Apply spatial filters
            lapData=obj.rawData.data*fltrWeights;
            
            % Apply freq filters
            outData=repmat(obj.rawData.data,1,nBands);
            for currFreq=1:nBands
                outData(:,(currFreq-1)*nChannels+1:currFreq*nChannels)=filter(B(currFreq,:),A(currFreq,:),lapData);
            end
            outData=outData.^2;
            for currFreq=1:nBands
                outData(:,(currFreq-1)*nChannels+1:currFreq*nChannels)=filter(Bfir,1,outData(:,(currFreq-1)*nChannels+1:currFreq*nChannels));
            end
            outData=log10(outData);
        end
        
        function obj=attachPhase(obj,otherSession)
            % Some fields may have an extra entry
            obj.outputLog.time=obj.outputLog.time(1:length(obj.outputLog.errPest));
            obj.outputLog.cursorPos=obj.outputLog.cursorPos(1:length(obj.outputLog.errPest));
            obj.outputLog.targetPos=obj.outputLog.targetPos(1:length(obj.outputLog.errPest));
            obj.outputLog.correctMovement=obj.outputLog.correctMovement(1:length(obj.outputLog.errPest));
            obj.timeTriggeredEvents{1}.triggersLog=obj.timeTriggeredEvents{1}.triggersLog(1:length(obj.outputLog.errPest));
            otherSession.outputLog.time=otherSession.outputLog.time(1:length(otherSession.outputLog.errPest));
            otherSession.outputLog.cursorPos=otherSession.outputLog.cursorPos(1:length(otherSession.outputLog.errPest));
            otherSession.outputLog.targetPos=otherSession.outputLog.targetPos(1:length(otherSession.outputLog.errPest));
            otherSession.outputLog.correctMovement=otherSession.outputLog.correctMovement(1:length(otherSession.outputLog.errPest));
            otherSession.timeTriggeredEvents{1}.triggersLog=otherSession.timeTriggeredEvents{1}.triggersLog(1:length(otherSession.outputLog.errPest));
            timeStep=median(diff(obj.rawData.time));
            otherSession.rawData.time=linspace(obj.rawData.time(end)+timeStep,obj.rawData.time(end)+otherSession.rawData.time(end),length(otherSession.rawData.time));
            joiningFields={'cursorPos','targetPos','errPest','MIest','correctMovement','MIindex','MIfeats','errPfeats'};
            updatingFields={'time','errPtimes','MItimes','MIupdateTime'};
            for currUpField=1:length(updatingFields)
                obj.outputLog.(updatingFields{currUpField})=cat(1,obj.outputLog.(updatingFields{currUpField}),otherSession.outputLog.(updatingFields{currUpField})+obj.rawData.time(end));
            end
            obj.outputLog.targetsReached.time=cat(1,obj.outputLog.targetsReached.time,otherSession.outputLog.targetsReached.time+obj.rawData.time(end));
            for currJoinField=1:length(joiningFields)
                if size(obj.outputLog.(joiningFields{currJoinField}),2)==size(otherSession.outputLog.(joiningFields{currJoinField}),2)
                    obj.outputLog.(joiningFields{currJoinField})=cat(1,obj.outputLog.(joiningFields{currJoinField}),otherSession.outputLog.(joiningFields{currJoinField}));
                else
                    obj.outputLog.(joiningFields{currJoinField})=cat(2,obj.outputLog.(joiningFields{currJoinField}),otherSession.outputLog.(joiningFields{currJoinField}));
                end
            end
            obj.outputLog.targetsReached.targetPos=cat(1,obj.outputLog.targetsReached.targetPos,otherSession.outputLog.targetsReached.targetPos);
            obj.outputLog.targetsReached.correctTarget=cat(1,obj.outputLog.targetsReached.correctTarget,otherSession.outputLog.targetsReached.correctTarget);
            for currTTE=1:length(obj.timeTriggeredEvents)
                obj.timeTriggeredEvents{currTTE}.triggersLog=cat(2,obj.timeTriggeredEvents{currTTE}.triggersLog,otherSession.timeTriggeredEvents{currTTE}.triggersLog+obj.rawData.time(end));
            end
            obj.rawData=append(obj.rawData,otherSession.rawData);
        end
        
        function testAdaptationGain(obj)
            % Compute estimations with final classifier
            computeProb=@(x)1./(1+exp(-(x*obj.MIclassifier.B+obj.MIclassifier.Intercept)));
            MIestEnd=computeProb(obj.outputLog.MIfeats(:,obj.MIclassifier.featsIdx));
            
            % Compute estimations with initial classifier
            obj.MIclassifier.Intercept=obj.outputLog.paramsHistory(1,1);
            obj.MIclassifier.B=obj.outputLog.paramsHistory(1,2:end)';
            computeProb=@(x)1./(1+exp(-(x*obj.MIclassifier.B+obj.MIclassifier.Intercept)));
            MIestStart=computeProb(obj.outputLog.MIfeats(:,obj.MIclassifier.featsIdx));
            
            lbls=double(obj.outputLog.targetPos(end-length(obj.outputLog.MIindex)+1:end)==1);
            lblsEstDyn=zeros(size(lbls));
            lblsEstEnd=zeros(size(lbls));
            lblsEstStart=zeros(size(lbls));
            for currTrial=1:length(lbls)
                lblsEstDyn(currTrial)=median(obj.outputLog.MIest(obj.outputLog.MIindex{currTrial}))<.5;
                lblsEstEnd(currTrial)=median(MIestEnd(obj.outputLog.MIindex{currTrial}))<.5;
                lblsEstStart(currTrial)=median(MIestStart(obj.outputLog.MIindex{currTrial}))<.5;
            end
            testAcc=@(x,y)(sum((x==1).*(y==1))./sum(x==1)+sum((x==0).*(y==0))./sum(x==0))*.5;
            dynBACC=testAcc(lbls,lblsEstDyn);
            endBACC=testAcc(lbls,lblsEstEnd);
            startBACC=testAcc(lbls,lblsEstStart);
            fprintf('Start classifier BAcc: %0.2f\nEnd classifier BAcc: %0.2f\nAdaptive BAcc: %0.2f\n',startBACC,endBACC,dynBACC);
        end
        
        function plotSpectrum(obj)
            % Around 5000 samples, in current setup, are affected with
            % startup artifact
            data=obj.rawData.data(5001:end,:);
            
            f=linspace(1/obj.fs,obj.fs,length(data));
            psd=abs(fft(detrend(data)));
            loglog(f,medfilt1(max(psd,[],2),7));
            xlim([f(2),obj.fs/2]);
        end
        
        function BP=trainOfflineMIclassifier(obj)
            outData=MI_errP.applyLapFilter(obj.rawData.data);
            winSampleLength=obj.fs*obj.timingParams.MIestimationLength;
            movIdx=find(ismember(obj.rawData.time,obj.outputLog.time));
            MIwins=MI_errP.recoverMIwins(outData,movIdx,winSampleLength); %#ok<FNDSB>
            freqRange=0:2:40;
            BP=MI_errP.recoverBP(MIwins,freqRange,obj.fs);
            keyboard;
        end
        
        %% Dependent properties
        function cTime=get.currTime(obj)
            if obj.isExpClosed
                cTime=obj.rawData.Time(end);
            else
                cTime=get_param(obj.modelName,'SimulationTime');
            end
        end
    end
    methods (Static)
        function [freqFeats,timeFeats]=preprocessData(dataWins)
            % This function takes either one time window as input (during
            % testing) or a vector of them (during training). Reshape
            % single window to make it consistent
            if length(size(dataWins))==2
                dataWins=reshape(dataWins,1,size(dataWins,1),size(dataWins,2));
            end
            [nWins,~,nChannels]=size(dataWins);
            timeFeats=zeros(size(dataWins,1),round(size(dataWins,2)/8),size(dataWins,3));
            freqFeats=zeros(nWins,129,nChannels);
            % Preprocess each input window
            for currWin=1:nWins
                for currCh=1:nChannels
                    relData=squeeze(dataWins(currWin,:,currCh));
                    % Normalize: set first sample to zero, sd to 1
                    relData=(relData-relData(1))/std(relData);
                    % Remove linear trend
                    relData=detrend(relData);
                    timeFeats(currWin,:,currCh)=resample(relData,64,512); % Resample time features at 64Hz (assuming a 512Hz original sampling rate)
                    % Compute log of bandpower
                    freqFeats(currWin,:,currCh)=pyulear(relData.*blackman(length(relData))',16);
                end
            end
            % Consider only frequencies up to ~60Hz
            freqFeats(:,31:end,:)=[];
            %             % Normalize, then extract logs
            %             freqFeats=freqFeats./repmat(sum(freqFeats,3),1,1,size(freqFeats,3));
            %             freqFeats=log(freqFeats);
        end
        
        function [outData,fltrWeights]=applyLapFilter(inData)
            try
                load('elMap16_MI_err.mat')
            catch ME %#ok<NASGU>
                warning('''elMap.mat'' not found. Electrode map required for laplacian filters.');
                outData=[];
                return;
            end
            fltrWeights=zeros(size(inData,2));
            for currEl=1:size(inData,2)
                neighborsMap=zeros(size(elMap16.elMat));
                neighborsMap(elMap16.elMat==currEl)=1;
                neighborsMap=imdilate(neighborsMap,strel('diamond',1));
                neighborsMap(elMap16.elMat==currEl)=0;
                validNeighbors=logical(neighborsMap.*elMap16.elMat);
                fltrWeights(currEl,elMap16.elMat(validNeighbors))=-1/sum(sum(validNeighbors));
                fltrWeights(currEl,currEl)=1;
            end
            outData=inData*fltrWeights';
        end
        
        function closeExp
            % Signals experiment to close
            assignin('base','isExpClosing',1);
        end
        
        function wOut=updateWeights(wIn,feats,E,t,lr)
            % feats new sample
            % E current classifier prediction
            % t true label
            feats=[1,feats];
            wOut=wIn+((lr*(t-E))'*feats)';
        end
        
        function objLong=joinSessions(fileNames)
            load(fileNames{1});
            objLong=obj;
            for currFile=2:length(fileNames)
                load(fileNames{currFile});
                objLong=attachPhase(objLong,obj);
            end
        end
        
        function [CARdata,coeff]=CARfilter(inData)
            CARdata=zeros(size(inData));
            coeff=zeros(1,size(inData,2));
            for currCh=1:size(inData,2)
                otherChsMedian=median(inData(:,[1:currCh-1,currCh+1:end]),2);
                coeff(currCh)=pinv(otherChsMedian)*inData(:,currCh);
                CARdata(:,currCh)=inData(:,currCh)-otherChsMedian*coeff(currCh);
            end
        end
        
        function MIwins=recoverMIwins(rawData,movIdx,winSampleLength)
            MIwins=zeros(length(movIdx),winSampleLength,size(rawData,2));
            for currTrial=1:length(movIdx)
                MIwins(currTrial,:,:)=rawData(movIdx(currTrial)-winSampleLength+1:movIdx(currTrial),:);
            end
        end
        
        function BP=recoverBP(MIwins,freqRange,fs)
            BP=zeros(size(MIwins,1),length(freqRange)-1,size(MIwins,3));
            for currTrial=1:size(BP,1)
                for currFreq=1:size(BP,2)
                    for currCh=1:size(BP,3)
                        BP(currTrial,currFreq,currCh)=bandpower(squeeze(MIwins(currTrial,:,currCh)).*blackman(size(MIwins,2))',fs,freqRange(currFreq:currFreq+1));
                    end
                end
            end
        end
    end
end

function simulinkModelStartFcn(modelName) %#ok<DEFNU>
% Start function for Simulink model.
blockName=sprintf('%s/filterBlock/log',modelName);
assignin('base','listenerMI',add_exec_event_listener(blockName,'PostOutputs',@acquireFreqFeats));
blockName=sprintf('%s/filterBlock/errP_buffer',modelName);
assignin('base','listenerErrP',add_exec_event_listener(blockName,'PostOutputs',@acquireErrPbufferedData));
end

function acquireFreqFeats(block,~)
assignin('base','BP',block.OutputPort(1).Data);
assignin('base','currTime',block.SampleTime);
end

function acquireErrPbufferedData(block,~)
assignin('base','currErrPdata',block.OutputPort(1).Data);
assignin('base','currErrPtime',block.SampleTime);
end

function onMouseMove(~,~)
% Makes mouse pointer invisible
if ~strcmp(get(gcf,'Pointer'),'custom')
    set(gcf,'PointerShapeCData',NaN(16));
    set(gcf,'Pointer','custom');
end
end

function KeyPressed(~,eventdata,~)
% This is called each time a keyboard key is pressed while the mouse cursor
% is within the window figure area
if strcmp(eventdata.Key,'escape')
    MI_errP.closeExp;
end
if strcmp(eventdata.Key,'p')
    keyboard;
    %     assignin('base','pauseNextTrial',1)
end
if strcmp(eventdata.Key,'t')
    assignin('base','toggleTraining',1);
end
if strcmp(eventdata.Key,'z')
    assignin('base','togglePause',1);
end
end

function OnClosing(~,~)
% Overrides normal closing procedure so that regardless of how figure is
% closed logged data is not lost
RT_MI_session.closeExp;
end