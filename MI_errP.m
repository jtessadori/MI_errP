classdef MI_errP
    properties
        fs=512; % WARNING: DO NOT change this. Amplifier acquisition rate can only be changed from its panel in Simulink, it is here for reference
        MIbufferLength=.4; % WARNING: as above, changing this here DOES NOT modify them in Simulink. Make sure desired lenghts are correct IN BOTH
        errPbufferLength=5; % Same as above. Parameters can be changed in triggeredBuffer block initialization mask in the Simulink block
        rawData;
        cursorPos;
        targetPos;
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
        learningRate=1e-2;
        nPositions=11; % Please, keep this odd
        vibrationParams;
        takeStep=@(obj)((rand>obj.trainingParams.errChance)-.5)*2*sign(obj.targetPos-obj.cursorPos);
    end
    properties (Dependent)
        currTime;
    end
    properties (Hidden)
        CDlength;
        possibleConditions={'Training','Testing'};
        isExpClosed=0;
        isTraining;
        actualTarget;
        lapFilterCoeffs;
        nextCursorPos;
        lastCursorPos;
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
            obj.CDlength=15;
            
            % Set desired length of recording
            obj.recLength=1200;
            
            % Define timing parameters
            obj.timingParams.targetReachedPause=2; % Wait at target position, once reached
            obj.timingParams.MIestimationLength=4; % Integrate data over this many seconds before drawing conclusion
            obj.timingParams.MIstepLength=.1; % Distance, in seconds, between evaluations of MI
            obj.timingParams.errPestimationLength=1; % Length of window used for errP estimation, following movement
            obj.timingParams.vibrationLength=1; % Length, in seconds, of armband vibration
            obj.timingParams.interStepInterval=obj.timingParams.MIestimationLength+obj.timingParams.errPestimationLength; % Wait between cursor movements, in seconds
            
            % Define squares positions
            obj.figureParams.squarePos=linspace(-.95,.95,obj.nPositions);
            
            % Define chance of error during training
            obj.trainingParams.errChance=0.3;
            
            % Set colors for different objects
            obj.colorScheme.bg=[.05,.05,.05];
            % Randomize color setup to reudce expectations
%             obj.colorScheme.targetColor=[.4,0,.1];
%             obj.colorScheme.cursorColorMI=[0,.4,0];
%             obj.colorScheme.cursorColorRest=[.4,.4,.4];
%             obj.colorScheme.cursorColorReached=[.6,.6,0];
            obj.colorScheme.possibleColors={[.4,0,.1],[0,.4,0],[.8,.2,0],[.6,.6,0]};
            obj.colorScheme.colorOrder=randperm(length(obj.colorScheme.possibleColors));
            obj.colorScheme.targetColor=obj.colorScheme.possibleColors{obj.colorScheme.colorOrder(1)};
            obj.colorScheme.cursorColorMI=obj.colorScheme.possibleColors{obj.colorScheme.colorOrder(2)};
            obj.colorScheme.cursorColorRest=obj.colorScheme.possibleColors{obj.colorScheme.colorOrder(3)};
            obj.colorScheme.cursorColorReached=obj.colorScheme.possibleColors{obj.colorScheme.colorOrder(4)};
            obj.colorScheme.cursorColor=obj.colorScheme.cursorColorMI;
            obj.colorScheme.edgeColor=[.4,.4,.4];
            
            % Set shape for squares
            obj.figureParams.squareShape.X=[-.05,.05,.05,-.05];
            obj.figureParams.squareShape.Y=[-.05,-.05,.05,.05];
            
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
            obj.outputLog.targetsReached.time=[];
            obj.outputLog.targetsReached.targetPos=[];
            obj.outputLog.correctMovement=[];
            obj.outputLog.MIindex=cell(0);
            obj.outputLog.MIfeats=[];
            obj.outputLog.MIupdateTime=[];
            obj.outputLog.paramsHistory=[];
            
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
            obj.modelName='SimpleAcquisition_16ch_2014a_MI_errP';
            
            % Prompts user to select a condition
            obj=selectCondition(obj);
            obj=setConditionSpecificParams(obj);
            
            % Determine starting position for cursor and target, and first
            % movement
            obj.targetPos=1+(randn>0)*(obj.nPositions-1);
            obj.cursorPos=(1+obj.nPositions)/2;
            if obj.isTraining
                % If training session, decide next position
                obj.nextCursorPos=min(obj.nPositions,max(1,obj.cursorPos+obj.takeStep(obj)));
            end
            
            % Prepares serial port for vibrating motor control
            obj.prepareSerialPort;
                        
            % Prepares Simulink model (i.e. starts recording, basically)
            obj.prepareSimulinkModel;
            
            % Opens black figure as background
            obj=createExpFigure(obj);
            
            % Generates array of time triggered events
            if obj.isTraining
                obj.timeTriggeredEvents{1}=timeTriggeredEvent('cursorMovementCallback',obj.timingParams.interStepInterval+obj.CDlength);
            else
                obj.timeTriggeredEvents{1}=timeTriggeredEvent('cursorMovementCallback',Inf);
            end
            obj.timeTriggeredEvents{2}=timeTriggeredEvent('processErrPbuffer',Inf);
            if obj.isTraining
                obj.timeTriggeredEvents{3}=timeTriggeredEvent('processMIbuffer',Inf);
            else
                obj.timeTriggeredEvents{3}=timeTriggeredEvent('processMIbuffer',0);
            end
            obj.timeTriggeredEvents{4}=timeTriggeredEvent('targetReachedCallback',Inf);
            obj.timeTriggeredEvents{5}=timeTriggeredEvent('estimateMovementDirection',Inf);
            obj.timeTriggeredEvents{6}=timeTriggeredEvent('switchToMIvibration',Inf);
            obj.timeTriggeredEvents{7}=timeTriggeredEvent('changeCursorColor',Inf);
            
            % Shows a countdown
            obj.startCountdown(obj.CDlength);
            
            % Perform bulk of experiment
            obj=manageExperiment(obj);
            
            % Closes exp window and saves data
            obj.closeExp;
        end
        
        function obj=manageExperiment(obj)
            % Generate file name used to save experiment data
            fileName=datestr(now,30);
            
            % If testing session, set first time retrieval of data
            if ~obj.isTraining
                obj.timeTriggeredEvents{5}.nextTrigger=obj.currTime+obj.timingParams.MIestimationLength;
            end
            
            % Experiment control loop
            while ~evalin('base','isExpClosing')&&obj.currTime<=(obj.recLength+obj.CDlength)
                pause(0.001);
                for currTTevent=1:length(obj.timeTriggeredEvents);
                    obj=checkAndExecute(obj.timeTriggeredEvents{currTTevent},obj.currTime,obj);
                    pause(0.0001);
                end
            end
            pause(3);
            obj.isExpClosed=1;
            delete(gcf);
            set_param(obj.modelName,'SimulationCommand','Stop');
            set_param(obj.modelName,'StartFcn','')
            obj.rawData=evalin('base','rawData');
            save(fileName,'obj');
            
            % Stop vibration and close serial port communication
            global motorSerialPort
            fprintf(motorSerialPort,'e8\n');
            pause(0.003)
            fprintf(motorSerialPort,'r0\n');
            pause(0.003)
            fprintf(motorSerialPort,'e4\n');
            pause(0.003)
            fprintf(motorSerialPort,'r0\n');
            fclose(motorSerialPort);
            delete(motorSerialPort);
            
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
            
            % Test if current target is reached
            if obj.cursorPos==obj.targetPos
                obj.timeTriggeredEvents{1}.nextTrigger=Inf;
                obj.timeTriggeredEvents{7}.nextTrigger=Inf;
                obj.timeTriggeredEvents{4}.nextTrigger=obj.currTime+obj.timingParams.targetReachedPause;
                set(obj.figureParams.cursorHandle,'XData',get(obj.figureParams.squareHandles(obj.cursorPos),'XData'),'FaceColor',obj.colorScheme.cursorColorReached);
                return; % Exit early from function
            else
                % Draw new cursor position
                set(obj.figureParams.cursorHandle,'XData',get(obj.figureParams.squareHandles(obj.cursorPos),'XData'),'FaceColor',obj.colorScheme.cursorColorRest);
            end
            
            if obj.isTraining
                % If training session, decide next position
                obj.nextCursorPos=min(obj.nPositions,max(1,obj.cursorPos+obj.takeStep(obj)));
                
                % Set next evaluation time for this function
                obj.timeTriggeredEvents{1}.nextTrigger=obj.currTime+obj.timingParams.interStepInterval;
            else
                % If testing session, set events to trigger data retrieval
                % and analysis of MI data
                obj.timeTriggeredEvents{5}.nextTrigger=obj.currTime+obj.timingParams.MIestimationLength;
                
                % Set next evaluation time for this function
                obj.timeTriggeredEvents{1}.nextTrigger=Inf;
                
                % Recover and log errP data
                obj.timeTriggeredEvents{2}.nextTrigger=obj.currTime+obj.timingParams.errPestimationLength;
            end
            
            % Add relevant info to log
            obj.outputLog.cursorPos=cat(1,obj.outputLog.cursorPos,obj.cursorPos);
            obj.outputLog.targetPos=cat(1,obj.outputLog.targetPos,obj.targetPos);
            obj.outputLog.time=cat(1,obj.outputLog.time,obj.currTime);
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
            lastCursorMovTime=obj.outputLog.time(end);
            currDelay=dataTimeStamp-lastCursorMovTime;
            dataWindow=dataWindow(round((obj.errPbufferLength-currDelay)*obj.fs+1):round((obj.errPbufferLength-currDelay+obj.timingParams.errPestimationLength)*obj.fs),:);
            
            % Perform classification
            lapData=dataWindow*obj.errPclassifier.lapFilterWeights;
            [freqFeats,timeFeats]=MI_errP.preprocessData(lapData);
            feats=reshape(cat(2,freqFeats,timeFeats),1,[]);
            currEst=obj.errPclassifier.clsfr.predict(feats(obj.errPclassifier.featsIdx));
%             currEst=obj.outputLog.correctMovement(end); % Comment this for actual experiment!!!!
%             currEst=1;
            
            % Update MI classifier parameters. Apply update on each data
            % sample that was predicting chosen class
            if ~currEst % i.e. an error is detected
                relSamples=obj.outputLog.MIindex{end};
                relEst=obj.outputLog.MIest(relSamples);
                majorityEst=median(relEst)>.5;
                relFeats=obj.outputLog.MIfeats(relSamples,:);
                updatingSamples=find((obj.outputLog.MIest(relSamples)>.5)==majorityEst);
                wIn=[obj.MIclassifier.Intercept;obj.MIclassifier.B];
                for currSample=1:length(updatingSamples)
                    feats=relFeats(updatingSamples(currSample),:);
                    E=relEst(updatingSamples(currSample));
                    t=~majorityEst; % Supposedly, I should be here only if last movement was wrong
                    wOut=MI_errP.updateWeights(wIn,feats,E,t,obj.learningRate);
                    obj.MIclassifier.Intercept=wOut(1);
                    obj.MIclassifier.B=wOut(2:end);
                end
                % Logs changing parameters
                obj.outputLog.MIupdateTime=cat(1,obj.outputLog.MIupdateTime,dataTimeStamp);
                obj.outputLog.paramsHistory=cat(1,obj.outputLog.paramsHistory,wIn');
            end
            
            % Log relevant data
            obj.outputLog.errPtimes=cat(1,obj.outputLog.errPtimes,dataTimeStamp);
            obj.outputLog.errPest=cat(1,obj.outputLog.errPest,currEst);
        end
        
        function obj=processMIbuffer(obj)
            % Log timing and reset trigger time
            obj.timeTriggeredEvents{3}.nextTrigger=obj.currTime+obj.timingParams.MIstepLength;
            obj.timeTriggeredEvents{3}.triggersLog=[obj.timeTriggeredEvents{3}.triggersLog,obj.currTime];
            
            % Recover data buffer from base workspace (Simulink puts them
            % there)
            dataWindow=evalin('base','currMIdata');
            dataTimeStamp=obj.currTime;
            
            % Perform classification
            lapData=dataWindow*obj.MIclassifier.lapFilterWeights;
            freqFeats=reshape(MI_errP.preprocessData(lapData),1,[]);
            computeProb=@(x)1./(1+exp(-(x*obj.MIclassifier.B+obj.MIclassifier.Intercept)));
            currProb=computeProb(freqFeats(obj.MIclassifier.featsIdx));
            
            % Log relevant data
            obj.outputLog.MItimes=cat(1,obj.outputLog.MItimes,dataTimeStamp);
            obj.outputLog.MIest=cat(1,obj.outputLog.MIest,currProb);
            obj.outputLog.MIfeats=cat(1,obj.outputLog.MIfeats,freqFeats(obj.MIclassifier.featsIdx));
        end
        
        function obj=targetReachedCallback(obj)
            % Log timing and reset trigger time
            obj.timeTriggeredEvents{4}.nextTrigger=Inf;
            obj.timeTriggeredEvents{4}.triggersLog=[obj.timeTriggeredEvents{4}.triggersLog,obj.currTime];
            
            % Add relevant info to log
            obj.outputLog.targetsReached.time=cat(1,obj.outputLog.targetsReached.time,obj.currTime);
            obj.outputLog.targetsReached.targetPos=cat(1,obj.outputLog.targetsReached.targetPos,obj.targetPos);
            
            % Reset cursor pos
            obj.cursorPos=(1+obj.nPositions)/2;
            set(obj.figureParams.cursorHandle,'XData',get(obj.figureParams.squareHandles(obj.cursorPos),'XData'),'FaceColor',obj.colorScheme.cursorColorMI);
            
            % Choose new target position and move it
            obj.targetPos=1+(randn>0)*(obj.nPositions-1);
            set(obj.figureParams.targetHandle,'XData',get(obj.figureParams.squareHandles(obj.targetPos),'XData'));
            
            if obj.isTraining
                % If training session, decide next position
                obj.nextCursorPos=min(obj.nPositions,max(1,obj.cursorPos+obj.takeStep(obj)));
                
                % Sets vibration cue
                obj.startBandVibration(obj.vibrationParams.MItrain,'MItraining');
            else
                % If testing session, set events to trigger data retrieval
                % and analysis
                obj.timeTriggeredEvents{5}.nextTrigger=obj.currTime+obj.timingParams.MIestimationLength;
            end
            
            % Set next cursor movement time
            obj.timeTriggeredEvents{1}.nextTrigger=obj.currTime+obj.timingParams.interStepInterval;
            
            % Add relevant info to log
            obj.outputLog.cursorPos=cat(1,obj.outputLog.cursorPos,obj.cursorPos);
            obj.outputLog.targetPos=cat(1,obj.outputLog.targetPos,obj.targetPos);
            obj.outputLog.time=cat(1,obj.outputLog.time,obj.currTime);
        end
        
        function obj=estimateMovementDirection(obj)
            % Log call timing
            obj.timeTriggeredEvents{5}.triggersLog=[obj.timeTriggeredEvents{5}.triggersLog,obj.currTime];
            
            % Next position is function of past classification results
            % (just take median of all available estimates in the window of
            % interest)
            if isempty(obj.outputLog.time)
                relevantEntries=obj.outputLog.MItimes>obj.CDlength;
            else
                relevantEntries=obj.outputLog.MItimes>obj.outputLog.time(end);
            end
            currEst=median(obj.outputLog.MIest(relevantEntries));
            
            % Verify whether current estimation is statistically
            % significant, otherwise keep adding data
            [~,isSignificant]=signrank(obj.outputLog.MIest(relevantEntries)-.5);
            
            if (isSignificant)||(obj.currTime-obj.outputLog.MItimes(find(relevantEntries,1,'first'))>10)
                suggestedMov=sign(currEst-.5);
                obj.nextCursorPos=min(obj.nPositions,max(1,obj.cursorPos+suggestedMov));
                
                % Log indexes of data used for estimation
                obj.outputLog.MIindex{end+1}=find(relevantEntries);
                
                % Reset trigger time
                obj.timeTriggeredEvents{5}.nextTrigger=Inf;
                
                % Perform suggested step and move on
                obj.timeTriggeredEvents{1}.nextTrigger=obj.currTime+obj.timingParams.interStepInterval;
            else
                % Re evaluate after more data have been collected
                obj.timeTriggeredEvents{5}.nextTrigger=obj.currTime+obj.timingParams.MIstepLength;
                obj.timeTriggeredEvents{1}.nextTrigger=Inf;
            end
        end
        
        function obj=switchToMIvibration(obj)
            % Log timing and reset trigger time
            obj.timeTriggeredEvents{6}.nextTrigger=Inf;
            obj.timeTriggeredEvents{6}.triggersLog=[obj.timeTriggeredEvents{6}.triggersLog,obj.currTime];
            
            % Send stop command to serial port
            global motorSerialPort
            fprintf(motorSerialPort,'r0\n\c');
            
            % Switch intensity level
            obj.startBandVibration(obj.vibrationParams.MItrain,'MItraining');
        end
        
        function obj=changeCursorColor(obj)
            % Log timing and reset trigger time
            obj.timeTriggeredEvents{7}.nextTrigger=Inf;
            obj.timeTriggeredEvents{7}.triggersLog=[obj.timeTriggeredEvents{7}.triggersLog,obj.currTime];
            
            % Send actual command to serial port
            set(obj.figureParams.cursorHandle,'FaceColor',obj.colorScheme.cursorColorMI);
        end
        
        function obj=selectCondition(obj)
            clc;
            for currPossibleCond=1:length(obj.possibleConditions)
                fprintf('[%d] - %s;\n',currPossibleCond,obj.possibleConditions{currPossibleCond});
            end
            currCond=input('\nPlease select desired condition: ');
            obj.condition.conditionID=currCond;
        end
        
        function obj=setConditionSpecificParams(obj)
            % 'Training','testing'
            switch obj.condition.conditionID
                case 1
                    obj.isTraining=1;
                case 2
                    obj.isTraining=0;
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
        
        function prepareSerialPort(obj) %#ok<MANU>
            global motorSerialPort
            motorSerialPort=serial('COM9','BaudRate',230400,'Parity','even');
            try
                fopen(motorSerialPort);
                pause(1);
                fprintf(motorSerialPort,'e4\n');
                pause(0.003);
                fprintf(motorSerialPort,'p\n');
                pause(0.003);
                fprintf(motorSerialPort,'e8\n');
                pause(0.003);
                fprintf(motorSerialPort,'p\n');
                pause(0.003);
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
                    textHandle=text(-.05,.5,num2str(cntDown));
                else
                    set(textHandle,'String',num2str(cntDown));
                end
                set(textHandle,'Color','white','FontSize',64);
                pause(1);
            end
            delete(textHandle);
        end
        
        function clsfr=computeErrPclassifier(obj)
            % Recover feats and labels
            [allFeats,lbls]=recoverErrPdata(obj);
                        
            % Make a first selection of relevant features
            classLbls=unique(lbls);
            m=zeros(length(classLbls),size(allFeats,2));
            md=zeros(size(m));
            for currClass=1:length(classLbls)
                % Use median and mad as proxy for mean and sd, to reduce
                % relevance of artifacts
                m(currClass,:)=median(allFeats(lbls==classLbls(currClass),:));
                md(currClass,:)=1.4826*mad(allFeats(lbls==classLbls(currClass),:),1);
            end
            computeWorth=@(m1,m2,md1,md2)abs((m1-m2)./sqrt(md1.^2+md2.^2));
            featWorth=computeWorth(m(1,:),m(2,:),md(1,:),md(2,:));
            
            % Keep features with a worth greater than 0.3 (keep at least
            % 15)
            [sortedWorth,featOrdr]=sort(featWorth,'descend');
            goodFeatsNumber=sum(sortedWorth>.2);
            goodFeatsIdx=featOrdr(1:max(15,goodFeatsNumber));
            feats=allFeats(:,goodFeatsIdx);
            
            % Train classifier
            fprintf('Training ErrP classifier. Please be patient, it will take some time...\n');
            clsfr.clsfr=fitcsvm(feats,lbls,'Standardize',true,'KernelScale','auto','KernelFunction','polynomial','PolynomialOrder',2);
            
            % Remove features ignored by model
            clsfr.featsIdx=goodFeatsIdx;
        end
        
        function [allFeats,lbls]=recoverErrPdata(obj)
            % Recover cursor movement times
            movTimes=obj.outputLog.time;
            
            % Compute cursor reset events index and remove them
            cursorReset=ismember(movTimes,obj.outputLog.targetsReached.time);
            movTimes(cursorReset)=[];
            
            % Recover windows after each movement
            winStarts=movTimes;
            winEnds=movTimes+obj.timingParams.errPestimationLength;
            
            % Convert to samples
            winStarts=winStarts*obj.fs;
            winEnds=winEnds*obj.fs;
            
            % Remove last window if longer than recording
            if winEnds(end)>length(obj.rawData.data)
                winStarts(end)=[];
                winEnds(end)=[];
            end
            
            % Recover data
            rawDataWins=zeros(length(winStarts),obj.timingParams.errPestimationLength*obj.fs,size(obj.rawData.data,2));
            for currWin=1:length(winStarts)
                rawDataWins(currWin,:,:)=obj.rawData.data(winStarts(currWin)+1:winEnds(currWin),:);
            end
            
            % Recover time and freq features
            [freqFeats,timeFeats]=MI_errP.preprocessData(rawDataWins);
            
            % Reshape feats
            allFeats=cat(2,freqFeats,timeFeats);
            allFeats=reshape(allFeats,size(allFeats,1),[]);
            
            % Recover lbls
            lbls=obj.outputLog.correctMovement;
            lbls(cursorReset)=[];
        end
        
        function AUC=testErrPclassifier(obj)
            % Recover feats and labels
            [allFeats,lbls]=recoverErrPdata(obj);
            
            % Define link function and compute estimates
            computeProb=@(x)1./(1+exp(-(x*obj.errPclassifier.B+obj.errPclassifier.Intercept)));
            errPest=computeProb(allFeats(:,obj.errPclassifier.featsIdx));
            
            % Compute AUC
            [~,~,~,AUC]=perfcurve(lbls,errPest,1);
        end
        
        function clsfr=computeMIclassifier(obj)
            % Recover MI data
            [allFeats,lbls]=recoverMIdata(obj);
                                                    
            % Make a first selection of relevant features
            classLbls=unique(lbls);
            m=zeros(length(classLbls),size(allFeats,2));
            md=zeros(size(m));
            for currClass=1:length(classLbls)
                % Use median and mad as proxy for mean and sd, to reduce
                % relevance of artifacts
                m(currClass,:)=median(allFeats(lbls==classLbls(currClass),:));
                md(currClass,:)=1.4826*mad(allFeats(lbls==classLbls(currClass),:),1);
            end
            computeWorth=@(m1,m2,md1,md2)abs((m1-m2)./sqrt(md1.^2+md2.^2));
            featWorth=computeWorth(m(1,:),m(2,:),md(1,:),md(2,:));
            
            % Keep only a very limited number of features (online training
            % will have issue working correctly, otherwise)
            [~,featOrdr]=sort(featWorth,'descend');
            goodFeatsIdx=featOrdr(1:25);
            feats=allFeats(:,goodFeatsIdx);
            
            % Train classifier
            fprintf('Training MI classifier. Please be patient, it will take some time...\n');
            [B,stats]=lassoglm(feats,lbls==1,'binomial','Alpha',.5,'CV',4);
            clsfr.B=B(:,stats.Index1SE);
            clsfr.Intercept=stats.Intercept(stats.Index1SE);
            
            % Remove features ignored by model
            ignoredFeats=B(:,stats.Index1SE)==0;
            clsfr.B(ignoredFeats)=[];
            clsfr.featsIdx=goodFeatsIdx;
            clsfr.featsIdx(ignoredFeats)=[];
        end
        
        function [allFeats,lbls]=recoverMIdata(obj)
%                         % Recover cursor movement times
%                         movTimes=obj.outputLog.time;
            
%                         % Recover all windows of defined length (MIbufferLength) for
%                         % which at least half the points lie in the interval of
%                         % interest (between movement and movement + MIestimationLength)
%                         sampleTimes=obj.rawData.time;
%                         distanceFromMovs=ones(length(movTimes),1)*sampleTimes'-movTimes*ones(1,length(sampleTimes));
%                         winStarts=find(sum((distanceFromMovs>-obj.MIbufferLength*.5+obj.timingParams.errPestimationLength)&(distanceFromMovs<obj.timingParams.MIestimationLength+obj.timingParams.errPestimationLength-obj.MIbufferLength*.5)));
%                         winEnds=winStarts+obj.timingParams.MIestimationLength*obj.fs;
%             
%                         % Subsample considered points: no need to have maximum possible
%                         % overlap between windows
%                         % WARNING: this is very significant subsampling. If needs be,
%                         % more points can be kept (it just makes classifier training
%                         % slower)
%                         winStarts=winStarts(1:100:end);
%                         winEnds=winEnds(1:100:end);
%             
%                         % Remove windows that exceed recording length
%                         toBeRemoved=winEnds>length(obj.rawData.time);
%                         winStarts(toBeRemoved)=[];
%                         winEnds(toBeRemoved)=[];

                        % Lap-filter data
                        lapData=MI_errP.applyLapFilter(obj.rawData.data);
            
%                         % Recover windows after each movement
%                         winStarts=movTimes+obj.timingParams.errPestimationLength;
%                         winEnds=movTimes+obj.timingParams.errPestimationLength+obj.timingParams.MIestimationLength;
%             
%                         % Convert to samples
%                         winStarts=winStarts*obj.fs;
%                         winEnds=winEnds*obj.fs;
%             
%                         % Recover data
%                         rawDataWins=zeros(length(winStarts),obj.timingParams.MIestimationLength*obj.fs,size(obj.rawData.data,2));
%                         for currWin=1:length(winStarts)
%                             rawDataWins(currWin,:,:)=lapData(winStarts(currWin)+1:winEnds(currWin),:);
%                         end
%             
%                         % Recover lbls
%                         lbls=double(obj.outputLog.targetPos>1);
%             
            % Recover data windows
            winStarts=round((0:0.25:obj.currTime-obj.MIbufferLength)*obj.fs);
            winEnds=winStarts+round(obj.MIbufferLength*obj.fs);
            rawDataWins=zeros(length(winStarts),round(obj.MIbufferLength*obj.fs),size(lapData,2));
            for currWin=1:length(winStarts)
                rawDataWins(currWin,:,:)=lapData(winStarts(currWin)+1:winEnds(currWin),:);
            end
            
            % Recover freq features only
            freqFeats=MI_errP.preprocessData(rawDataWins);
            
            % Reshape feats
            allFeats=reshape(freqFeats,size(freqFeats,1),[]);
            
            % Recover only actually relevant windows
            movTimes=obj.outputLog.time*obj.fs;
            distanceFromMovs=(ones(length(movTimes),1)*winStarts-movTimes*ones(1,length(winStarts)))/obj.fs;
            distanceFromMovs(distanceFromMovs<0)=Inf;
            relevantWindows=(min(distanceFromMovs)>1.2)&(min(distanceFromMovs)<4.8);
            
            % Recover lbls
            lbls=zeros(length(obj.rawData.time),1);
            lbls(1:obj.outputLog.targetsReached.time(1)*obj.fs)=obj.outputLog.targetsReached.targetPos(1)>1;
            for currTarget=2:length(obj.outputLog.targetsReached.targetPos)
                lbls(obj.outputLog.targetsReached.time(currTarget-1)*obj.fs+1:obj.outputLog.targetsReached.time(currTarget)*obj.fs)=obj.outputLog.targetsReached.targetPos(currTarget)>1;
            end
            lbls(obj.outputLog.targetsReached.time(end)*obj.fs+1:end)=obj.outputLog.targetPos(end)>1;
            lbls=lbls(winStarts+round(obj.MIbufferLength*.5*obj.fs));
            
            % Remove data and lbls outside of windows of interest
            lbls=lbls(relevantWindows);
            allFeats=allFeats(relevantWindows,:);

            % Remove first entries, possibly affected by stabilization of
            % filters
            lbls(1:200)=[];
            allFeats(1:200,:)=[];
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
            MIestLong=computeProb(obj.outputLog.MIfeats);
            
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
            % Intensity will be passed as a parameter between 0 and 1. Need
            % to rescale it as an integer between 0 and 120 for serial port
            % to work properly
            serialIntensity=round(intensity*120);
            
            % Use global variable for motorSerialPort so that it can be
            % accessed also in case of unexpected program stop
            global motorSerialPort
            switch vibrationType
                case 'feedback' % Vibration position should match last cursor movement
                    vibrationDir=obj.lastCursorPos-obj.cursorPos;
                case 'MItraining' % Vibration position should match current direction
                    vibrationDir=sign(obj.cursorPos-obj.targetPos);
            end
            switch vibrationDir
                case -1
                    fprintf(motorSerialPort,'e4\n');
                    pause(0.003);
                    fprintf(motorSerialPort,'r%d\n',serialIntensity);
                    pause(0.003);
                    fprintf(motorSerialPort,'e8\n');
                    pause(0.003);
                    fprintf(motorSerialPort,'r0\n');
                case 1
                    fprintf(motorSerialPort,'e8\n');
                    pause(0.003)
                    fprintf(motorSerialPort,'r%d\n',serialIntensity);
                    pause(0.003);
                    fprintf(motorSerialPort,'e4\n');
                    pause(0.003);
                    fprintf(motorSerialPort,'r0\n');
                case 0
                    fprintf(motorSerialPort,'e8\n');
                    pause(0.003)
                    fprintf(motorSerialPort,'r0\n');
                    pause(0.003);
                    fprintf(motorSerialPort,'e4\n');
                    pause(0.003);
                    fprintf(motorSerialPort,'r0\n');
            end
        end
        
        function outData=preProcData(obj)
            % Prepare freq filters
            windowLength=.4;
            nBands=29;
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
    end
end

function simulinkModelStartFcn(modelName) %#ok<DEFNU>
% Start function for Simulink model.
blockName=sprintf('%s/triggeredBuffer/MI_buffer',modelName);
assignin('base','listenerMI',add_exec_event_listener(blockName,'PostOutputs',@acquireMIbufferedData));
blockName=sprintf('%s/triggeredBuffer/errP_buffer',modelName);
assignin('base','listenerErrP',add_exec_event_listener(blockName,'PostOutputs',@acquireErrPbufferedData));
end

function acquireMIbufferedData(block,~)
assignin('base','currMIdata',block.OutputPort(1).Data);
assignin('base','currTime',block.SampleTime);
end

function acquireErrPbufferedData(block,~)
assignin('base','currErrPdata',block.OutputPort(1).Data);
assignin('base','currTime',block.SampleTime);
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
end

function OnClosing(~,~)
% Overrides normal closing procedure so that regardless of how figure is
% closed logged data is not lost
RT_MI_session.closeExp;
end